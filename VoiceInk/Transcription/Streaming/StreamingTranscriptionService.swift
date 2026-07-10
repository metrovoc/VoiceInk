import Foundation
import SwiftData

/// The single cadence gate between provider events and UI publication. Event
/// reduction remains unthrottled inside `StreamingTranscriptionCore`; only
/// immutable snapshots crossing to MainActor are coalesced.
final class StreamingPartialEventCoalescer: @unchecked Sendable {
    private struct Payload: @unchecked Sendable {
        let snapshot: StreamingTranscriptSnapshot?
        let legacyText: String
    }

    /// Mutable lock-owned batches avoid repeatedly copying an ever-growing
    /// `appendedSegments` array. The accumulator is moved out atomically, then
    /// materialized exactly once off-lock for immutable MainActor delivery.
    private struct PendingAccumulator {
        var latestRevision: UInt64?
        var segmentBatches: [[StreamingTranscriptSegment]] = []
        var segmentCount = 0
        var latestPartial: String?
        var latestLegacyText = ""

        init(_ payload: Payload) {
            merge(payload)
        }

        mutating func merge(_ payload: Payload) {
            latestLegacyText = payload.legacyText
            guard let snapshot = payload.snapshot else {
                latestRevision = nil
                segmentBatches.removeAll(keepingCapacity: true)
                segmentCount = 0
                latestPartial = nil
                return
            }

            latestRevision = snapshot.revision
            if !snapshot.appendedSegments.isEmpty {
                segmentBatches.append(snapshot.appendedSegments)
                segmentCount += snapshot.appendedSegments.count
            }
            latestPartial = snapshot.partial
        }

        func materialize() -> Payload {
            guard let latestRevision else {
                return Payload(snapshot: nil, legacyText: latestLegacyText)
            }

            var segments: [StreamingTranscriptSegment] = []
            segments.reserveCapacity(segmentCount)
            for batch in segmentBatches {
                segments.append(contentsOf: batch)
            }
            return Payload(
                snapshot: StreamingTranscriptSnapshot(
                    revision: latestRevision,
                    appendedSegments: segments,
                    partial: latestPartial
                ),
                legacyText: latestLegacyText
            )
        }
    }

    struct MetricsSnapshot: Sendable, Equatable {
        let submittedSegments: Int
        let materializedSegments: Int
        let pendingSegments: Int
        let maximumPendingSegments: Int
        let deliveryCount: Int
        let workerStartCount: Int
    }

    private let lock = NSLock()
    private let interval: TimeInterval
    private var pendingAccumulator: PendingAccumulator?
    private var lastEmitTime: TimeInterval = 0
    private var workerTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var submittedSegments = 0
    private var materializedSegments = 0
    private var maximumPendingSegments = 0
    private var deliveryCount = 0
    private var workerStartCount = 0

    init(interval: TimeInterval = 0.040) {
        self.interval = interval
    }

    /// Compatibility overload retained for focused coalescer tests and legacy
    /// consumers. The production core uses the structured snapshot overload.
    func submit(
        _ text: String,
        emit: @escaping @MainActor @Sendable (String) -> Void
    ) {
        submit(Payload(snapshot: nil, legacyText: text)) { payload in
            emit(payload.legacyText)
        }
    }

    func submit(
        snapshot: StreamingTranscriptSnapshot,
        legacyText: String,
        emit: @escaping @MainActor @Sendable (StreamingTranscriptSnapshot, String) -> Void
    ) {
        submit(Payload(snapshot: snapshot, legacyText: legacyText)) { payload in
            guard let snapshot = payload.snapshot else { return }
            emit(snapshot, payload.legacyText)
        }
    }

    func cancel() {
        lock.lock()
        generation &+= 1
        pendingAccumulator = nil
        workerTask?.cancel()
        workerTask = nil
        lastEmitTime = 0
        lock.unlock()
    }

    var metricsSnapshot: MetricsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return MetricsSnapshot(
            submittedSegments: submittedSegments,
            materializedSegments: materializedSegments,
            pendingSegments: pendingAccumulator?.segmentCount ?? 0,
            maximumPendingSegments: maximumPendingSegments,
            deliveryCount: deliveryCount,
            workerStartCount: workerStartCount
        )
    }

    private func submit(
        _ payload: Payload,
        emit: @escaping @MainActor @Sendable (Payload) -> Void
    ) {
        lock.lock()
        let appendedCount = payload.snapshot?.appendedSegments.count ?? 0
        submittedSegments += appendedCount
        if pendingAccumulator == nil {
            pendingAccumulator = PendingAccumulator(payload)
        } else {
            pendingAccumulator?.merge(payload)
        }
        maximumPendingSegments = max(
            maximumPendingSegments,
            pendingAccumulator?.segmentCount ?? 0
        )
        guard workerTask == nil else {
            lock.unlock()
            return
        }

        let currentGeneration = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runWorker(generation: currentGeneration, emit: emit)
        }
        workerTask = task
        workerStartCount += 1
        lock.unlock()
    }

    /// One worker owns both the cadence wait and MainActor delivery. While the
    /// main actor is busy, producers only replace `pendingPayload`; no extra
    /// MainActor jobs can accumulate.
    private func runWorker(
        generation expectedGeneration: UInt64,
        emit: @escaping @MainActor @Sendable (Payload) -> Void
    ) async {
        while !Task.isCancelled {
            guard let delay = workerDelay(generation: expectedGeneration) else { return }

            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }

            guard let accumulator = takePendingAccumulator(
                generation: expectedGeneration
            ) else { return }
            let payload = accumulator.materialize()
            recordMaterialization(segmentCount: accumulator.segmentCount)

            guard isCurrentGeneration(expectedGeneration) else { return }
            await MainActor.run {
                guard self.isCurrentGeneration(expectedGeneration) else { return }
                emit(payload)
            }

            guard completeDelivery(generation: expectedGeneration) else { return }
        }
    }

    private func workerDelay(generation expectedGeneration: UInt64) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expectedGeneration, pendingAccumulator != nil else {
            if generation == expectedGeneration { workerTask = nil }
            return nil
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - lastEmitTime
        return UInt64(max(0, interval - elapsed) * 1_000_000_000)
    }

    private func takePendingAccumulator(
        generation expectedGeneration: UInt64
    ) -> PendingAccumulator? {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expectedGeneration,
              let accumulator = pendingAccumulator else {
            if generation == expectedGeneration { workerTask = nil }
            return nil
        }
        pendingAccumulator = nil
        return accumulator
    }

    private func completeDelivery(generation expectedGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expectedGeneration else { return false }
        deliveryCount += 1
        lastEmitTime = ProcessInfo.processInfo.systemUptime
        guard pendingAccumulator != nil else {
            workerTask = nil
            return false
        }
        return true
    }

    private func isCurrentGeneration(_ expectedGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == expectedGeneration
    }

    private func recordMaterialization(segmentCount: Int) {
        lock.lock()
        materializedSegments += segmentCount
        lock.unlock()
    }
}

/// Lifecycle states for a streaming transcription session.
enum StreamingState: Sendable, Equatable {
    case idle
    case connecting
    case streaming
    case committing
    case done
    case failed
    case cancelled
}

protocol StreamingTranscriptionServicing: AnyObject, Sendable {
    @MainActor
    var isActive: Bool { get }

    @MainActor
    func startStreaming(model: any TranscriptionModel, context: TranscriptionRequestContext) async throws

    nonisolated func sendAudioChunk(_ data: Data)

    @MainActor
    func stopAndGetFinalText() async throws -> String

    @MainActor
    func cancel()
}

/// Optional capability used by the concrete realtime service. Keeping it
/// separate preserves compatibility with lightweight test doubles.
@MainActor
protocol StreamingPerformanceTracing: AnyObject, Sendable {
    func setPerformanceTrace(_ trace: RealtimePerformanceTrace?)
}

/// Binds the hardware producer's per-recording continuity token to the
/// streaming facade. The service will not accept a successful final result
/// until hardware capture has sealed and late upstream/downstream drops have
/// both been rechecked.
@MainActor
protocol StreamingAudioContinuityBinding: AnyObject, Sendable {
    func bindAudioContinuity(_ continuity: RecordingAudioContinuity?)
}

/// Starts provider finalization from a generic executor. Once this method has
/// returned, progress no longer depends on MainActor availability.
protocol StreamingImmediateFinalizing: AnyObject, Sendable {
    nonisolated func requestFinalizationTask() -> Task<String, Error>
}

/// Constructs the provider snapshot synchronously on MainActor, then submits
/// connection work to core before `prepare()` returns its audio callback.
@MainActor
protocol StreamingImmediateStarting: AnyObject, Sendable {
    func requestStartTask(
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) -> Task<Void, Error>
}

/// MainActor-facing compatibility facade. Provider I/O, queue draining, event
/// aggregation, and finalization are all owned by `StreamingTranscriptionCore`.
@MainActor
final class StreamingTranscriptionService:
    StreamingTranscriptionServicing,
    StreamingPerformanceTracing,
    StreamingAudioContinuityBinding,
    StreamingImmediateStarting,
    StreamingImmediateFinalizing
{
    typealias ProviderFactory = @Sendable (
        any TranscriptionModel,
        [String],
        FluidAudioTranscriptionService?
    ) throws -> any StreamingTranscriptionProvider

    private struct ProviderStartInput: @unchecked Sendable {
        let model: any TranscriptionModel
        let fluidAudioService: FluidAudioTranscriptionService?
        let language: String
        let trace: RealtimePerformanceTrace?
        let usesVocabulary: Bool
    }

    private let modelContainer: StreamingVocabularyContainerReference
    private let vocabularySnapshotStore: StreamingVocabularySnapshotStore
    private let fluidAudioService: FluidAudioTranscriptionService?
    private let providerFactory: ProviderFactory
    private let audioQueue: StreamingAudioQueue
    private let telemetry: StreamingTelemetry
    private let core: StreamingTranscriptionCore
    private let audioContinuityBinding = RecordingAudioContinuityBinding()
    private var performanceTrace: RealtimePerformanceTrace?
    private var connectionTask: Task<Void, Error>?

    init(
        modelContainer: ModelContainer,
        fluidAudioService: FluidAudioTranscriptionService? = nil,
        onPartialTranscript: (@MainActor @Sendable (String) -> Void)? = nil,
        onTranscriptSnapshot: (@MainActor @Sendable (StreamingTranscriptSnapshot) -> Void)? = nil,
        providerFactory: ProviderFactory? = nil,
        vocabularySnapshotStore: StreamingVocabularySnapshotStore = .shared,
        maxBufferedChunks: Int = 600,
        maximumQueueAge: TimeInterval = RealtimePerformanceBudget.maximumStreamingQueueAge,
        partialPublicationInterval: TimeInterval = 0.040,
        drainTimeoutNanoseconds: UInt64 = 3_000_000_000,
        finalCommitTimeoutNanoseconds: UInt64 = 10_000_000_000,
        disconnectTimeoutNanoseconds: UInt64 = 2_000_000_000
    ) {
        let audioQueue = StreamingAudioQueue(capacity: maxBufferedChunks)
        let telemetry = StreamingTelemetry(maximumPermittedQueueAge: maximumQueueAge)
        let coalescer = StreamingPartialEventCoalescer(interval: partialPublicationInterval)

        self.modelContainer = StreamingVocabularyContainerReference(modelContainer)
        self.vocabularySnapshotStore = vocabularySnapshotStore
        self.fluidAudioService = fluidAudioService
        if let providerFactory {
            self.providerFactory = providerFactory
        } else {
            self.providerFactory = { model, vocabulary, fluidAudioService in
                try Self.defaultProviderFactory(
                    model: model,
                    customVocabulary: vocabulary,
                    fluidAudioService: fluidAudioService
                )
            }
        }
        self.audioQueue = audioQueue
        self.telemetry = telemetry
        self.core = StreamingTranscriptionCore(
            audioQueue: audioQueue,
            telemetry: telemetry,
            partialCoalescer: coalescer,
            drainTimeoutNanoseconds: drainTimeoutNanoseconds,
            finalCommitTimeoutNanoseconds: finalCommitTimeoutNanoseconds,
            disconnectTimeoutNanoseconds: disconnectTimeoutNanoseconds,
            onPartialTranscript: onPartialTranscript,
            onTranscriptSnapshot: onTranscriptSnapshot
        )
    }

    deinit {
        connectionTask?.cancel()
        audioQueue.cancel(
            recordingDiscardedWith: telemetry,
            marksAudioDiscontinuity: false
        )
        let core = core
        Task.detached(priority: .utility) {
            await core.cancel()
        }
    }

    var isActive: Bool {
        let state = metricsSnapshot.state
        return state == .streaming || state == .committing
    }

    nonisolated var metricsSnapshot: StreamingMetricsSnapshot {
        telemetry.snapshot(queue: audioQueue.snapshot())
    }

    func setPerformanceTrace(_ trace: RealtimePerformanceTrace?) {
        performanceTrace = trace
        let core = core
        Task.detached(priority: .userInitiated) {
            await core.updatePerformanceTrace(trace)
        }
    }

    func bindAudioContinuity(_ continuity: RecordingAudioContinuity?) {
        audioContinuityBinding.bind(continuity)
    }

    func startStreaming(
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) async throws {
        try await requestStartTask(model: model, context: context).value
    }

    func requestStartTask(
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) -> Task<Void, Error> {
        if let connectionTask { return connectionTask }

        let core = core
        let providerFactory = providerFactory
        let vocabularySnapshotStore = vocabularySnapshotStore
        let modelContainer = modelContainer
        let input = ProviderStartInput(
            model: model,
            fluidAudioService: fluidAudioService,
            language: context.language ?? "auto",
            trace: performanceTrace,
            usesVocabulary: CloudProviderRegistry.usesStreamingVocabulary(for: model.provider)
        )

        // Task submission is the synchronous hot-path operation. Vocabulary
        // loading and provider construction begin only inside this detached
        // preconnect task, so neither SwiftData nor provider setup can delay
        // recorder/audio startup.
        let task = Task.detached(priority: .userInitiated) {
            let vocabulary: [String]
            if input.usesVocabulary {
                vocabulary = await vocabularySnapshotStore
                    .snapshot(for: modelContainer)
                    .terms
            } else {
                vocabulary = []
            }
            let provider = try providerFactory(
                input.model,
                vocabulary,
                input.fluidAudioService
            )
            try await core.start(
                provider: provider,
                model: input.model,
                language: input.language,
                performanceTrace: input.trace
            )
        }
        connectionTask = task
        return task
    }

    nonisolated func sendAudioChunk(_ data: Data) {
        let now = ProcessInfo.processInfo.systemUptime
        switch audioQueue.enqueue(data, now: now) {
        case .enqueued(let depth, let oldestAge):
            telemetry.recordEnqueue(
                byteCount: data.count,
                depth: depth,
                oldestAge: oldestAge
            )
        case .enqueuedDroppingOldest(
            let droppedBytes,
            let droppedAge,
            let depth,
            let oldestAge
        ):
            telemetry.recordEnqueue(
                byteCount: data.count,
                depth: depth,
                oldestAge: oldestAge
            )
            telemetry.recordDropped(byteCount: droppedBytes, age: droppedAge)
            audioQueue.cancel(
                recordingDiscardedWith: telemetry,
                marksAudioDiscontinuity: true,
                now: now
            )
        case .terminated(let marksAudioDiscontinuity):
            telemetry.recordEnqueue(byteCount: data.count, depth: 0, oldestAge: 0)
            telemetry.recordDiscarded(
                chunkCount: 1,
                byteCount: data.count,
                maximumAge: 0,
                marksAudioDiscontinuity: marksAudioDiscontinuity
            )
        }
    }

    func stopAndGetFinalText() async throws -> String {
        try await Self.finalTextAfterContinuityValidation(
            core: core,
            audioQueue: audioQueue,
            telemetry: telemetry,
            continuity: audioContinuityBinding.snapshot()
        )
    }

    nonisolated func requestFinalizationTask() -> Task<String, Error> {
        let core = core
        let audioQueue = audioQueue
        let telemetry = telemetry
        let continuity = audioContinuityBinding.snapshot()
        return Task.detached(priority: .userInitiated) {
            try await Self.finalTextAfterContinuityValidation(
                core: core,
                audioQueue: audioQueue,
                telemetry: telemetry,
                continuity: continuity
            )
        }
    }

    func cancel() {
        // Close ingress synchronously so the realtime callback cannot add work
        // while actor teardown waits to run.
        audioQueue.cancel(
            recordingDiscardedWith: telemetry,
            marksAudioDiscontinuity: false
        )
        telemetry.setState(.cancelled)
        connectionTask?.cancel()
        let core = core
        Task.detached(priority: .userInitiated) {
            await core.cancel()
        }
    }

    private nonisolated static func finalTextAfterContinuityValidation(
        core: StreamingTranscriptionCore,
        audioQueue: StreamingAudioQueue,
        telemetry: StreamingTelemetry,
        continuity: RecordingAudioContinuity?
    ) async throws -> String {
        let text = try await core.stopAndGetFinalText()

        // Provider finalization intentionally overlaps AudioOutputUnitStop. A
        // fast final acknowledgement must still wait for the hardware seal so
        // a pipe overflow or a tail chunk rejected after requestCommit cannot
        // race a successful return.
        if let continuity {
            await continuity.waitUntilCaptureSealed()
        }

        let hardware = continuity?.snapshot()
        let transport = telemetry.snapshot(queue: audioQueue.snapshot())
        let droppedChunks = (hardware?.streamingDroppedChunks ?? 0) + transport.droppedChunks
        let droppedBytes = (hardware?.streamingDroppedBytes ?? 0) + transport.droppedBytes
        guard droppedChunks == 0, droppedBytes == 0 else {
            throw StreamingTranscriptionError.audioDropped(
                chunks: droppedChunks,
                bytes: droppedBytes
            )
        }
        return text
    }

    private nonisolated static func defaultProviderFactory(
        model: any TranscriptionModel,
        customVocabulary: [String],
        fluidAudioService: FluidAudioTranscriptionService?
    ) throws -> any StreamingTranscriptionProvider {
        if model.provider == .fluidAudio {
            if FluidAudioModelManager.isNemotronModel(named: model.name) {
                return FluidAudioNemotronStreamingProvider()
            }
            if FluidAudioModelManager.isParakeetUnifiedModel(named: model.name) {
                return FluidAudioUnifiedStreamingProvider()
            }
            guard let fluidAudioService else {
                throw StreamingTranscriptionError.connectionFailed(
                    "FluidAudioTranscriptionService is unavailable"
                )
            }
            return FluidAudioStreamingProvider(fluidAudioService: fluidAudioService)
        }

        guard let cloudProvider = CloudProviderRegistry.provider(for: model.provider),
              let provider = cloudProvider.makeStreamingProvider(
                customVocabulary: customVocabulary
              ) else {
            throw StreamingTranscriptionError.connectionFailed(
                "Unsupported streaming provider: \(model.provider)"
            )
        }
        return provider
    }
}
