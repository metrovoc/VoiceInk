import Foundation
import SwiftData
import Testing
@testable import VoiceInk_CE

@Suite(.serialized)
struct StreamingTranscriptionCoreTests {
    @MainActor
    @Test func sustainedTenThousandChunkStreamPreservesEveryChunk() async throws {
        let provider = LockedStreamingProvider(
            commitEvents: [.committed(text: "complete")]
        )
        let service = try makeService(
            provider: provider,
            maxBufferedChunks: 12_000,
            maximumQueueAge: 10
        )
        try await start(service)

        await withTaskGroup(of: Void.self) { group in
            for producer in 0..<10 {
                group.addTask {
                    for index in 0..<1_000 {
                        service.sendAudioChunk(
                            Data([UInt8(producer), UInt8(truncatingIfNeeded: index)])
                        )
                        if index.isMultiple(of: 64) {
                            await Task.yield()
                        }
                    }
                }
            }
        }

        let text = try await service.stopAndGetFinalText()
        let metrics = service.metricsSnapshot

        #expect(text == "complete")
        #expect(metrics.receivedChunks == 10_000)
        #expect(metrics.sentChunks == 10_000)
        #expect(metrics.droppedChunks == 0)
        #expect(metrics.queueDepth == 0)
        #expect(metrics.audioDiscontinuity == nil)
        #expect(provider.commitCallCount == 1)
    }

    @MainActor
    @Test func concurrentFinalizationRequestsShareExactlyOneCommit() async throws {
        let provider = LockedStreamingProvider(
            commitEvents: [.committed(text: "one final")]
        )
        let service = try makeService(provider: provider)
        try await start(service)

        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<32 {
                let task = service.requestFinalizationTask()
                group.addTask { try await task.value }
            }
            var values: [String] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        #expect(results.count == 32)
        #expect(results.allSatisfy { $0 == "one final" })
        #expect(provider.commitCallCount == 1)
        #expect(service.metricsSnapshot.stopToCommitDispatch.map { $0 <= 0.050 } == true)
    }

    @MainActor
    @Test func queueOverflowIsAnExplicitDiscontinuityAndNeverCommits() async throws {
        let provider = LockedStreamingProvider(
            commitEvents: [.committed(text: "must not be accepted")],
            sendDelayNanoseconds: 200_000_000
        )
        let service = try makeService(provider: provider, maxBufferedChunks: 2)
        try await start(service)

        for byte in 0..<100 {
            service.sendAudioChunk(Data([UInt8(byte)]))
        }

        do {
            _ = try await service.stopAndGetFinalText()
            Issue.record("Expected an explicit audioDropped failure")
        } catch StreamingTranscriptionError.audioDropped(let chunks, _) {
            #expect(chunks > 0)
        } catch {
            Issue.record("Expected audioDropped, got \(error)")
        }

        let metrics = service.metricsSnapshot
        #expect(metrics.sentChunks + metrics.droppedChunks == metrics.receivedChunks)
        #expect(metrics.sentBytes + metrics.droppedBytes == metrics.receivedBytes)
        #expect(metrics.audioDiscontinuity == .audioDropped)
        #expect(provider.commitCallCount == 0)
    }

    @MainActor
    @Test func slowSingleSendReportsAgeBudgetWithoutRejectingContinuousAudio() async throws {
        let provider = LockedStreamingProvider(
            commitEvents: [.committed(text: "continuous")],
            sendDelayNanoseconds: 130_000_000
        )
        let service = try makeService(provider: provider, maxBufferedChunks: 8)
        try await start(service)
        service.sendAudioChunk(Data([0x01]))

        let text = try await service.stopAndGetFinalText()
        let metrics = service.metricsSnapshot

        #expect(text == "continuous")
        #expect(metrics.sentChunks == 1)
        #expect(metrics.droppedChunks == 0)
        #expect(metrics.queueAgeBudgetExceeded)
        #expect(metrics.maximumQueueAge >= 0.100)
        #expect(metrics.audioDiscontinuity == nil)
        #expect(provider.commitCallCount == 1)
    }

    @MainActor
    @Test func halfSecondHandshakePreservesStartupAudioAndPublishesPartial() async throws {
        let provider = LockedStreamingProvider(
            commitEvents: [.committed(text: "complete")],
            connectDelayNanoseconds: 500_000_000,
            partialTextOnFirstAudio: "live words"
        )
        var snapshots: [StreamingTranscriptSnapshot] = []
        let service = try makeService(
            provider: provider,
            partialPublicationInterval: 0.010,
            onTranscriptSnapshot: { snapshots.append($0) }
        )
        let startTask = service.requestStartTask(
            model: streamingCoreModel(),
            context: TranscriptionRequestContext(language: "en", prompt: nil)
        )

        let chunkCount = 50
        for index in 0..<chunkCount {
            service.sendAudioChunk(Data([UInt8(index)]))
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await startTask.value

        let partialPublished = await waitUntil(timeout: 1) {
            snapshots.last?.partial == "live words"
        }
        let text = try await service.stopAndGetFinalText()
        let metrics = service.metricsSnapshot

        #expect(partialPublished)
        #expect(text == "complete")
        #expect(provider.sentChunks == chunkCount)
        #expect(metrics.receivedChunks == chunkCount)
        #expect(metrics.sentChunks == chunkCount)
        #expect(metrics.droppedChunks == 0)
        #expect(metrics.audioDiscontinuity == nil)
        #expect(provider.commitCallCount == 1)
    }

    @MainActor
    @Test func ordinaryCommitDuringDrainCannotAcknowledgeExplicitCommit() async throws {
        let provider = LockedStreamingProvider(
            commitEvents: [],
            sendDelayNanoseconds: 80_000_000,
            emitsFinalizedOnCommit: false
        )
        let service = try makeService(
            provider: provider,
            finalCommitTimeoutNanoseconds: 25_000_000
        )
        try await start(service)
        service.sendAudioChunk(Data([0x01]))

        let finalization = service.requestFinalizationTask()
        try await Task.sleep(nanoseconds: 10_000_000)
        provider.emit(.committed(text: "ordinary segment"))

        do {
            _ = try await finalization.value
            Issue.record("A pre-commit segment must not satisfy explicit finalization")
        } catch StreamingTranscriptionError.timeout {
            #expect(provider.commitCallCount == 1)
        } catch {
            Issue.record("Expected final-ack timeout, got \(error)")
        }
    }

    @MainActor
    @Test func queuedOrdinaryCommitRemainsSegmentUntilDistinctFinalizedAck() async throws {
        let provider = LockedStreamingProvider(
            commitEvents: [.committed(text: "tail")]
        )
        let service = try makeService(provider: provider)
        try await start(service)

        // Intentionally do not yield: this ordinary segment may still be queued
        // when the explicit commit generation begins.
        provider.emit(.committed(text: "earlier"))
        let text = try await service.requestFinalizationTask().value

        #expect(text == "earlier tail")
        #expect(provider.commitCallCount == 1)
    }

    @MainActor
    @Test func partialEventStormPublishesMonotonicCoalescedSnapshots() async throws {
        let provider = LockedStreamingProvider(
            commitEvents: [.committed(text: "final")]
        )
        var snapshots: [StreamingTranscriptSnapshot] = []
        let service = try makeService(
            provider: provider,
            partialPublicationInterval: 0.010,
            onTranscriptSnapshot: { snapshots.append($0) }
        )
        try await start(service)

        for revision in 0..<10_000 {
            provider.emit(.partial(text: "hypothesis \(revision)"))
        }

        let observedLatestPartial = await waitUntil(timeout: 2) {
            snapshots.last?.partial == "hypothesis 9999"
        }
        #expect(observedLatestPartial)

        provider.emit(.committed(text: "stable"))

        let observedStable = await waitUntil(timeout: 2) {
            snapshots.last?.appendedSegments.last?.text == "stable"
        }
        #expect(observedStable)

        let finalText = try await service.stopAndGetFinalText()
        let revisions = snapshots.map(\.revision)
        #expect(finalText == "stable final")
        #expect(
            zip(revisions, revisions.dropFirst()).allSatisfy { pair in
                pair.0 < pair.1
            }
        )
        #expect(snapshots.count < 1_000)

        let stableIDs = snapshots
            .compactMap { snapshot in
                snapshot.appendedSegments.first(where: { $0.text == "stable" })?.id
            }
        #expect(Set(stableIDs).count <= 1)
    }

    @Test func providerRelayKeepsLatestPartialAndAllControlEvents() async throws {
        let relay = StreamingProviderEventRelay()
        for index in 0..<100_000 {
            relay.yield(.partial(text: "partial \(index)"))
        }

        var iterator = relay.stream.makeAsyncIterator()
        guard case .partial(let latest)? = await iterator.next() else {
            Issue.record("Expected latest partial")
            return
        }
        #expect(latest == "partial 99999")

        relay.yield(.committed(text: "stable"))
        relay.yield(.finalized)
        relay.finish()

        guard case .committed(let stable)? = await iterator.next() else {
            Issue.record("Expected lossless committed event")
            return
        }
        #expect(stable == "stable")
        guard case .finalized? = await iterator.next() else {
            Issue.record("Expected lossless finalized event")
            return
        }
        if case .some = await iterator.next() {
            Issue.record("Expected relay exhaustion")
        }
    }

    @Test func providerRelayOverflowIsBoundedAndFailsExplicitly() async {
        let relay = StreamingProviderEventRelay(maxBufferedControlEvents: 3)
        let stream = relay.stream
        relay.yield(.committed(text: "one"))
        relay.yield(.committed(text: "two"))
        relay.yield(.committed(text: "three"))
        relay.yield(.committed(text: "four"))

        var iterator = stream.makeAsyncIterator()
        guard case .error(let error)? = await iterator.next(),
              let streamingError = error as? StreamingTranscriptionError,
              case .eventBacklogExceeded(let limit) = streamingError else {
            Issue.record("Expected explicit bounded-backlog failure")
            return
        }
        #expect(limit == 3)
        if case .some = await iterator.next() {
            Issue.record("Expected relay exhaustion after terminal overflow")
        }
    }

    @MainActor
    @Test func coalescerQueuesAtMostOneMainActorDeliveryWhileMainIsBlocked() async throws {
        let coalescer = StreamingPartialEventCoalescer(interval: 0.010)
        let producerStarted = DispatchSemaphore(value: 0)
        let blocker = DispatchSemaphore(value: 0)
        let delivered = LockedStringDeliveryCollector()

        let producer = Task.detached {
            producerStarted.signal()
            for index in 0..<10_000 {
                coalescer.submit("value \(index)") { value in
                    delivered.append(value)
                }
            }
        }

        _ = StreamingBlockingWait.wait(producerStarted, timeout: .now() + 1)
        _ = StreamingBlockingWait.wait(
            blocker,
            timeout: .now() + .milliseconds(100)
        )
        await producer.value
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(delivered.count <= 2)
        #expect(delivered.last == "value 9999")
    }

    @MainActor
    @Test func tenThousandCommittedEventsStayLinearAndLosslessAtUIBoundary() async throws {
        let provider = LockedStreamingProvider(
            commitEvents: [.committed(text: "tail")]
        )
        var snapshots: [StreamingTranscriptSnapshot] = []
        let service = try makeService(
            provider: provider,
            partialPublicationInterval: 0.010,
            onTranscriptSnapshot: { snapshots.append($0) }
        )
        try await start(service)

        for index in 0..<10_000 {
            provider.emit(.committed(text: "segment\(index)"))
        }
        let receivedAll = await waitUntil(timeout: 2) {
            snapshots.reduce(into: 0) { $0 += $1.appendedSegments.count } == 10_000
        }

        #expect(receivedAll)
        #expect(snapshots.count < 100)
        let segments = snapshots.flatMap(\.appendedSegments)
        #expect(Set(segments.map(\.id)).count == 10_000)
        #expect(segments.first?.text == "segment0")
        #expect(segments.last?.text == "segment9999")

        provider.emit(.partial(text: "bounded hypothesis tail"))
        let receivedTail = await waitUntil(timeout: 2) {
            snapshots.last?.partial == "bounded hypothesis tail"
        }
        #expect(receivedTail)

        let final = try await service.stopAndGetFinalText()
        #expect(final.hasSuffix("segment9999 tail"))
    }

    @MainActor
    @Test func blockedMainCoalescerMaterializesTenThousandCommittedDeltasOnce() async throws {
        let coalescer = StreamingPartialEventCoalescer(interval: 0)
        let producerStarted = DispatchSemaphore(value: 0)
        let producerFinished = DispatchSemaphore(value: 0)
        let delivered = LockedSegmentDeliveryCollector()

        let producer = Task.detached {
            producerStarted.signal()
            for index in 0..<10_000 {
                let segment = StreamingTranscriptSegment(
                    id: UInt64(index + 1),
                    text: "segment\(index)"
                )
                coalescer.submit(
                    snapshot: StreamingTranscriptSnapshot(
                        revision: UInt64(index + 1),
                        appendedSegments: [segment],
                        partial: nil
                    ),
                    legacyText: ""
                ) { snapshot, _ in
                    delivered.record(snapshot)
                }
            }
            producerFinished.signal()
        }

        _ = StreamingBlockingWait.wait(producerStarted, timeout: .now() + 1)
        #expect(
            StreamingBlockingWait.wait(producerFinished, timeout: .now() + 2) == .success
        )
        await producer.value

        let deliveredAll = await waitUntil(timeout: 2) {
            delivered.segmentCount == 10_000
        }
        let metrics = coalescer.metricsSnapshot

        #expect(deliveredAll)
        #expect(delivered.deliveryCount <= 2)
        #expect(metrics.submittedSegments == 10_000)
        #expect(metrics.materializedSegments == 10_000)
        #expect(metrics.pendingSegments == 0)
        #expect(metrics.maximumPendingSegments <= 10_000)
        #expect(metrics.deliveryCount <= 2)
        #expect(metrics.workerStartCount == 1)
    }

    @MainActor
    @Test func cancellationSealsIngressAndDisconnectsProvider() async throws {
        let provider = LockedStreamingProvider(
            commitEvents: [.committed(text: "unused")],
            sendDelayNanoseconds: 5_000_000_000
        )
        let service = try makeService(provider: provider)
        try await start(service)
        service.sendAudioChunk(Data([0x01, 0x02]))
        let sendStarted = await waitUntil(timeout: 1) {
            provider.sendAttemptCount == 1
        }
        #expect(sendStarted)
        service.sendAudioChunk(Data([0x03, 0x04, 0x05]))

        service.cancel()
        service.sendAudioChunk(Data([0x06]))
        let disconnected = await waitUntil(timeout: 1) {
            provider.disconnectCallCount == 1
        }
        let metrics = service.metricsSnapshot

        #expect(disconnected)
        #expect(metrics.state == .cancelled)
        #expect(metrics.receivedChunks == 3)
        #expect(metrics.sentChunks == 0)
        #expect(metrics.droppedChunks == 3)
        #expect(metrics.receivedBytes == 6)
        #expect(metrics.sentBytes == 0)
        #expect(metrics.droppedBytes == 6)
        #expect(metrics.audioDiscontinuity == nil)
        #expect(provider.commitCallCount == 0)
    }

    @MainActor
    @Test func providerErrorClaimsInFlightAndBufferedAudioBeforeCommit() async throws {
        let provider = LockedStreamingProvider(
            commitEvents: [.committed(text: "must not commit")],
            sendDelayNanoseconds: 5_000_000_000
        )
        let service = try makeService(provider: provider)
        try await start(service)
        service.sendAudioChunk(Data([0x01, 0x02]))
        let sendStarted = await waitUntil(timeout: 1) {
            provider.sendAttemptCount == 1
        }
        #expect(sendStarted)
        service.sendAudioChunk(Data([0x03, 0x04, 0x05]))

        let finalization = service.requestFinalizationTask()
        provider.emit(.error(StreamingTranscriptionError.serverError("terminal")))

        do {
            _ = try await finalization.value
            Issue.record("Expected the provider error to win before commit")
        } catch StreamingTranscriptionError.serverError(let message) {
            #expect(message == "terminal")
        } catch {
            Issue.record("Expected provider serverError, got \(error)")
        }

        let metrics = service.metricsSnapshot
        #expect(metrics.receivedChunks == 2)
        #expect(metrics.sentChunks == 0)
        #expect(metrics.droppedChunks == 2)
        #expect(metrics.receivedBytes == 5)
        #expect(metrics.sentBytes == 0)
        #expect(metrics.droppedBytes == 5)
        #expect(metrics.audioDiscontinuity == nil)
        #expect(provider.commitCallCount == 0)
    }

    @Test func commitSealCannotBeDowngradedByCleanupBeforeLateIngress() {
        let queue = StreamingAudioQueue(capacity: 2)
        let telemetry = StreamingTelemetry(maximumPermittedQueueAge: 0.100)

        queue.requestCommit()
        queue.cancel(
            recordingDiscardedWith: telemetry,
            marksAudioDiscontinuity: false
        )

        switch queue.enqueue(Data([0x01, 0x02])) {
        case .terminated(let marksAudioDiscontinuity):
            #expect(marksAudioDiscontinuity)
        default:
            Issue.record("Expected commit-sealed ingress to remain terminal")
        }
    }

    @MainActor
    @Test func prepareThenImmediateFinalizeCannotOvertakeStart() async throws {
        let provider = LockedStreamingProvider(
            commitEvents: [.committed(text: "immediate")],
            connectDelayNanoseconds: 20_000_000
        )
        let service = try makeService(provider: provider)
        let batch = StreamingCoreBatchFallback(result: "batch")
        let session = StreamingTranscriptionSession(
            streamingService: service,
            fallbackService: batch
        )
        let configuration = TranscriptionRuntimeConfiguration(
            mode: nil,
            model: streamingCoreModel(),
            language: "en",
            isRealtimeEnabled: true
        )

        _ = try await session.prepare(configuration: configuration)
        session.requestFinalization(trace: nil)
        let text = try await session.transcribe(
            audioURL: URL(fileURLWithPath: "/tmp/voiceink-immediate.wav")
        )

        #expect(text == "immediate")
        #expect(provider.connectCallCount == 1)
        #expect(provider.commitCallCount == 1)
        #expect(batch.callCount == 0)
    }

    @MainActor
    @Test func startTimeoutDoesNotWaitForCancellationIgnoringConnect() async throws {
        let provider = LockedStreamingProvider(
            commitEvents: [.committed(text: "too late")],
            connectDelayNanoseconds: 300_000_000,
            ignoresConnectCancellation: true
        )
        let service = try makeService(provider: provider)
        let batch = StreamingCoreBatchFallback(result: "bounded fallback")
        let session = StreamingTranscriptionSession(
            streamingService: service,
            fallbackService: batch,
            streamingStartTimeoutNanoseconds: 20_000_000
        )
        let configuration = TranscriptionRuntimeConfiguration(
            mode: nil,
            model: streamingCoreModel(),
            language: "en",
            isRealtimeEnabled: true
        )

        _ = try await session.prepare(configuration: configuration)
        let startedAt = ProcessInfo.processInfo.systemUptime
        session.requestFinalization(trace: nil)
        let text = try await session.transcribe(
            audioURL: URL(fileURLWithPath: "/tmp/voiceink-timeout.wav")
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        #expect(text == "bounded fallback")
        #expect(elapsed < 0.150)
        #expect(batch.callCount == 1)
        #expect(provider.commitCallCount == 0)
    }

    @MainActor
    @Test func slowDisconnectNeverDelaysFinalResultAndRunsExactlyOnce() async throws {
        let provider = LockedStreamingProvider(
            commitEvents: [.committed(text: "ready")],
            disconnectDelayNanoseconds: 300_000_000
        )
        let service = try makeService(provider: provider)
        try await start(service)

        let startedAt = ProcessInfo.processInfo.systemUptime
        let text = try await service.stopAndGetFinalText()
        let resultElapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let teardownCompleted = await waitUntil(timeout: 1) {
            provider.disconnectCompletedCount == 1
        }

        #expect(text == "ready")
        #expect(resultElapsed < 0.050)
        #expect(teardownCompleted)
        #expect(provider.disconnectCallCount == 1)
        #expect(provider.disconnectCompletedCount == 1)
    }

    @MainActor
    private func makeService(
        provider: LockedStreamingProvider,
        maxBufferedChunks: Int = 600,
        maximumQueueAge: TimeInterval = RealtimePerformanceBudget.maximumStreamingQueueAge,
        partialPublicationInterval: TimeInterval = 0.040,
        finalCommitTimeoutNanoseconds: UInt64 = 500_000_000,
        onTranscriptSnapshot: (@MainActor @Sendable (StreamingTranscriptSnapshot) -> Void)? = nil
    ) throws -> StreamingTranscriptionService {
        StreamingTranscriptionService(
            modelContainer: try streamingCoreModelContainer(),
            onTranscriptSnapshot: onTranscriptSnapshot,
            providerFactory: { _, _, _ in provider },
            maxBufferedChunks: maxBufferedChunks,
            maximumQueueAge: maximumQueueAge,
            partialPublicationInterval: partialPublicationInterval,
            drainTimeoutNanoseconds: 3_000_000_000,
            finalCommitTimeoutNanoseconds: finalCommitTimeoutNanoseconds,
            disconnectTimeoutNanoseconds: 200_000_000
        )
    }

    @MainActor
    private func start(_ service: StreamingTranscriptionService) async throws {
        try await service.startStreaming(
            model: streamingCoreModel(),
            context: TranscriptionRequestContext(language: "en", prompt: nil)
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }
}

@MainActor
private func streamingCoreModelContainer() throws -> ModelContainer {
    let schema = Schema([Transcription.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return container
}

private func streamingCoreModel() -> CloudModel {
    CloudModel(
        name: "deepgram-live",
        displayName: "deepgram-live",
        description: "Streaming core test model",
        provider: .deepgram,
        speed: 1,
        accuracy: 1,
        isMultilingual: true,
        supportsStreaming: true,
        supportedLanguages: ["en": "English"]
    )
}

private final class LockedStreamingProvider: StreamingTranscriptionProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let eventContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    private let commitEvents: [StreamingTranscriptionEvent]
    private let connectDelayNanoseconds: UInt64
    private let sendDelayNanoseconds: UInt64
    private let disconnectDelayNanoseconds: UInt64
    private let ignoresConnectCancellation: Bool
    private let emitsFinalizedOnCommit: Bool
    private let partialTextOnFirstAudio: String?
    private var _connectCallCount = 0
    private var _sendAttemptCount = 0
    private var _sentChunks = 0
    private var _commitCallCount = 0
    private var _disconnectCallCount = 0
    private var _disconnectCompletedCount = 0

    init(
        commitEvents: [StreamingTranscriptionEvent],
        connectDelayNanoseconds: UInt64 = 0,
        sendDelayNanoseconds: UInt64 = 0,
        disconnectDelayNanoseconds: UInt64 = 0,
        ignoresConnectCancellation: Bool = false,
        emitsFinalizedOnCommit: Bool = true,
        partialTextOnFirstAudio: String? = nil
    ) {
        self.commitEvents = commitEvents
        self.connectDelayNanoseconds = connectDelayNanoseconds
        self.sendDelayNanoseconds = sendDelayNanoseconds
        self.disconnectDelayNanoseconds = disconnectDelayNanoseconds
        self.ignoresConnectCancellation = ignoresConnectCancellation
        self.emitsFinalizedOnCommit = emitsFinalizedOnCommit
        self.partialTextOnFirstAudio = partialTextOnFirstAudio
        let (stream, continuation) = AsyncStream.makeStream(
            of: StreamingTranscriptionEvent.self
        )
        transcriptionEvents = stream
        eventContinuation = continuation
    }

    var connectCallCount: Int { withLock { _connectCallCount } }
    var sendAttemptCount: Int { withLock { _sendAttemptCount } }
    var sentChunks: Int { withLock { _sentChunks } }
    var commitCallCount: Int { withLock { _commitCallCount } }
    var disconnectCallCount: Int { withLock { _disconnectCallCount } }
    var disconnectCompletedCount: Int { withLock { _disconnectCompletedCount } }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        withLock { _connectCallCount += 1 }
        if connectDelayNanoseconds > 0 {
            if ignoresConnectCancellation {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(
                        deadline: .now() + .nanoseconds(Int(connectDelayNanoseconds))
                    ) {
                        continuation.resume()
                    }
                }
            } else {
                try await Task.sleep(nanoseconds: connectDelayNanoseconds)
            }
        }
        eventContinuation.yield(.sessionStarted)
    }

    func sendAudioChunk(_ data: Data) async throws {
        withLock { _sendAttemptCount += 1 }
        if sendDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: sendDelayNanoseconds)
        }
        let isFirstChunk = withLock {
            _sentChunks += 1
            return _sentChunks == 1
        }
        if isFirstChunk, let partialTextOnFirstAudio {
            eventContinuation.yield(.partial(text: partialTextOnFirstAudio))
        }
    }

    func commit() async throws {
        withLock { _commitCallCount += 1 }
        for event in commitEvents {
            eventContinuation.yield(event)
        }
        if emitsFinalizedOnCommit {
            eventContinuation.yield(.finalized)
        }
    }

    func disconnect() async {
        withLock { _disconnectCallCount += 1 }
        if disconnectDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: disconnectDelayNanoseconds)
        }
        withLock { _disconnectCompletedCount += 1 }
        eventContinuation.finish()
    }

    func emit(_ event: StreamingTranscriptionEvent) {
        eventContinuation.yield(event)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class StreamingCoreBatchFallback: TranscriptionService, @unchecked Sendable {
    private let lock = NSLock()
    private let result: String
    private var _callCount = 0

    init(result: String) {
        self.result = result
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    func transcribe(
        audioURL: URL,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) async throws -> String {
        withLock { _callCount += 1 }
        return result
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class LockedStringDeliveryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    var last: String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.last
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class LockedSegmentDeliveryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [StreamingTranscriptSegment] = []
    private var deliveries = 0

    var segmentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return segments.count
    }

    var deliveryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return deliveries
    }

    func record(_ snapshot: StreamingTranscriptSnapshot) {
        lock.lock()
        deliveries += 1
        segments.append(contentsOf: snapshot.appendedSegments)
        lock.unlock()
    }
}

private enum StreamingBlockingWait {
    static func wait(
        _ semaphore: DispatchSemaphore,
        timeout: DispatchTime
    ) -> DispatchTimeoutResult {
        semaphore.wait(timeout: timeout)
    }
}
