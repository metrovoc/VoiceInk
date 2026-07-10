import Foundation
import SwiftData
import Testing
@testable import VoiceInk_CE

@Suite(.serialized)
struct RecordingAudioContinuityTests {
    @Test func realtimeProducerPathContainsNoLockAllocationOrExecutorHop() throws {
        let source = try projectSource("VoiceInk/CoreAudioRecorder.swift")
        let pipe = try #require(
            source.components(separatedBy: "final class RealtimeAudioChunkPipe").last
        )
        let enqueue = try #require(
            pipe.components(separatedBy: "func enqueue(_ bytes: UnsafeRawPointer, byteCount: Int)").last?
                .components(separatedBy: "private func consumeUntilStopped").first
        )

        #expect(!enqueue.contains("lock()"))
        #expect(!enqueue.contains("Data("))
        #expect(!enqueue.contains("Task"))
        #expect(!enqueue.contains("await"))
        #expect(enqueue.contains("writeIndex.store"))
    }

    @Test func streamingRingReleasesStorageOnlyAfterPayloadCopy() throws {
        let source = try projectSource("VoiceInk/CoreAudioRecorder.swift")
        let pipe = try #require(
            source.components(separatedBy: "final class RealtimeAudioChunkPipe").last
        )
        let drain = try #require(
            pipe.components(separatedBy: "private func drainAvailable()").last?
                .components(separatedBy: "private func reset()").first
        )
        let payloadCopy = try #require(
            drain.range(of: "readFromRing(", options: .backwards)
        )
        let release = try #require(
            drain.range(
                of: "readIndex.store(read + UInt64(totalByteCount), ordering: .releasing)",
                options: .backwards
            )
        )

        #expect(payloadCopy.lowerBound < release.lowerBound)
    }

    @Test func realtimePipeOverflowMarksSharedContinuityWithoutAudioThreadCallbackWork() {
        let continuity = RecordingAudioContinuity()
        let pipe = RealtimeAudioChunkPipe(capacity: 20)
        let callbackStarted = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let callbackGate = LockedOneShotGate()
        pipe.setContinuity(continuity)
        pipe.callback = { _ in
            if callbackGate.take() {
                callbackStarted.signal()
                releaseCallback.wait()
            }
        }
        pipe.start()

        enqueue(Data(repeating: 1, count: 8), into: pipe)
        #expect(AudioContinuityBlockingWait.wait(callbackStarted, timeout: .now() + 1) == .success)

        // One 8-byte payload plus its 4-byte length header fits. The next one
        // must be rejected in O(1) while the consumer is deliberately stalled.
        enqueue(Data(repeating: 2, count: 8), into: pipe)
        enqueue(Data(repeating: 3, count: 8), into: pipe)

        releaseCallback.signal()
        let stats = pipe.stopAndDrain()
        let snapshot = continuity.snapshot()

        #expect(stats.droppedChunks == 1)
        #expect(stats.droppedBytes == 8)
        #expect(snapshot.streamingDroppedChunks == 1)
        #expect(snapshot.streamingDroppedBytes == 8)
    }

    @Test func pipeReportsBufferedTailWhenCallbackIsDetachedBeforeDrain() {
        let continuity = RecordingAudioContinuity()
        let pipe = RealtimeAudioChunkPipe(capacity: 64)
        let callbackStarted = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        pipe.setContinuity(continuity)
        pipe.callback = { _ in
            callbackStarted.signal()
            releaseCallback.wait()
        }
        pipe.start()

        enqueue(Data(repeating: 1, count: 8), into: pipe)
        #expect(AudioContinuityBlockingWait.wait(callbackStarted, timeout: .now() + 1) == .success)
        enqueue(Data(repeating: 2, count: 8), into: pipe)
        pipe.callback = nil
        releaseCallback.signal()

        let stats = pipe.stopAndDrain()
        let snapshot = continuity.snapshot()
        #expect(stats.droppedChunks == 1)
        #expect(stats.droppedBytes == 8)
        #expect(snapshot.hasStreamingDiscontinuity)
    }

    @Test func stopBarrierDeliversEveryAcceptedStreamingTailBeforeFileDrain() throws {
        let continuity = RecordingAudioContinuity()
        let pipe = RealtimeAudioChunkPipe(capacity: 8_192)
        let collector = LockedByteCollector()
        pipe.setContinuity(continuity)
        pipe.callback = { data in
            if let value = data.first {
                collector.append(value)
            }
        }
        pipe.start()

        for value in UInt8(0)..<100 {
            enqueue(Data([value]), into: pipe)
        }
        let stats = pipe.stopAndDrain()

        #expect(stats.droppedChunks == 0)
        #expect(stats.droppedBytes == 0)
        #expect(collector.values == Array(UInt8(0)..<100))
        #expect(!continuity.snapshot().hasStreamingDiscontinuity)

        let source = try projectSource("VoiceInk/CoreAudioRecorder.swift")
        let stopBody = try #require(
            source.components(separatedBy: "func stopRecording(onStreamingDrained:").last?
                .components(separatedBy: "private func sealAndReleaseAudioContinuity").first
        )
        let streamingDrain = try #require(stopBody.range(of: "audioChunkPipe.stopAndDrain()"))
        let stopTail = stopBody[streamingDrain.lowerBound...]
        let barrier = try #require(stopTail.range(of: "onStreamingDrained?()"))
        let fileDrain = try #require(stopTail.range(of: "audioFileWriter.stopAndDrain()"))
        #expect(streamingDrain.lowerBound < barrier.lowerBound)
        #expect(barrier.lowerBound < fileDrain.lowerBound)
    }

    @Test func fileOnlyModeDisablesStreamingDropAccounting() {
        let continuity = RecordingAudioContinuity()
        continuity.disableStreamingTracking()
        continuity.recordStreamingDrop(byteCount: 320)

        let snapshot = continuity.snapshot()
        #expect(snapshot.streamingDroppedChunks == 0)
        #expect(snapshot.streamingDroppedBytes == 0)
    }

    @Test func fileIntegrityFailureIsPubliclyObservable() {
        let continuity = RecordingAudioContinuity()
        continuity.recordFileDrop(byteCount: 640)
        continuity.recordFileWriteError()
        continuity.sealCapture()

        let snapshot = continuity.snapshot()
        #expect(snapshot.hasFileDiscontinuity)
        #expect(snapshot.fileDroppedChunks == 1)
        #expect(snapshot.fileDroppedBytes == 640)
        #expect(snapshot.fileWriteErrors == 1)
        #expect(snapshot.isCaptureSealed)
    }

    @MainActor
    @Test func fileSessionNeverUploadsAnIncompleteRecording() async throws {
        let service = AudioContinuityBatchService()
        let session = FileTranscriptionSession(service: service)
        let continuity = RecordingAudioContinuity()
        continuity.recordFileDrop(byteCount: 640)
        continuity.sealCapture()
        session.setAudioContinuity(continuity)
        _ = try await session.prepare(
            configuration: TranscriptionRuntimeConfiguration(
                mode: nil,
                model: audioContinuityModel(),
                language: "en",
                isRealtimeEnabled: false
            )
        )

        do {
            _ = try await session.transcribe(audioURL: URL(fileURLWithPath: "/tmp/incomplete.wav"))
            Issue.record("Expected incomplete file rejection")
        } catch RecordingAudioIntegrityError.incompleteFile(
            let droppedChunks,
            let droppedBytes,
            let writeErrors
        ) {
            #expect(droppedChunks == 1)
            #expect(droppedBytes == 640)
            #expect(writeErrors == 0)
        } catch {
            Issue.record("Expected incompleteFile, got \(error)")
        }
        #expect(service.callCount == 0)
    }

    @MainActor
    @Test func serviceRejectsFinalIfHardwareDropArrivesAfterCommit() async throws {
        let provider = AudioContinuityStreamingProvider()
        let service = try makeService(provider: provider)
        let continuity = RecordingAudioContinuity()
        service.bindAudioContinuity(continuity)
        try await service.startStreaming(
            model: audioContinuityModel(),
            context: TranscriptionRequestContext(language: "en", prompt: nil)
        )

        let finalization = service.requestFinalizationTask()
        let didCommit = await waitUntil { provider.commitCallCount == 1 }
        #expect(didCommit)

        // The provider has already acknowledged commit, but the service cannot
        // return success until the shared hardware producer seals.
        continuity.recordStreamingDrop(byteCount: 320)
        continuity.sealCapture()

        do {
            _ = try await finalization.value
            Issue.record("Expected a late hardware discontinuity to reject the final result")
        } catch StreamingTranscriptionError.audioDropped(let chunks, let bytes) {
            #expect(chunks == 1)
            #expect(bytes == 320)
        } catch {
            Issue.record("Expected audioDropped, got \(error)")
        }
    }

    @MainActor
    @Test func serviceWaitsForHardwareSealBeforeReturningSuccessfulFinal() async throws {
        let provider = AudioContinuityStreamingProvider()
        let service = try makeService(provider: provider)
        let continuity = RecordingAudioContinuity()
        service.bindAudioContinuity(continuity)
        try await service.startStreaming(
            model: audioContinuityModel(),
            context: TranscriptionRequestContext(language: "en", prompt: nil)
        )

        let startedAt = ProcessInfo.processInfo.systemUptime
        let finalization = service.requestFinalizationTask()
        let didCommit = await waitUntil { provider.commitCallCount == 1 }
        #expect(didCommit)
        try await Task.sleep(nanoseconds: 30_000_000)
        continuity.sealCapture()

        let text = try await finalization.value
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        #expect(text == "complete")
        #expect(elapsed >= 0.025)
    }

    private func enqueue(_ data: Data, into pipe: RealtimeAudioChunkPipe) {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            pipe.enqueue(baseAddress, byteCount: bytes.count)
        }
    }

    private func projectSource(_ relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @MainActor
    private func makeService(
        provider: AudioContinuityStreamingProvider
    ) throws -> StreamingTranscriptionService {
        // Keep the container alive while the service captures its background
        // vocabulary reference. A standalone ModelContext does not own the
        // temporary in-memory container that created it.
        let container = try audioContinuityModelContainer()
        return StreamingTranscriptionService(
            modelContainer: container,
            providerFactory: { _, _, _ in provider },
            finalCommitTimeoutNanoseconds: 500_000_000
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 1,
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

private final class LockedByteCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt8] = []

    var values: [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: UInt8) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class LockedOneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard available else { return false }
        available = false
        return true
    }
}

@MainActor
private func audioContinuityModelContainer() throws -> ModelContainer {
    let schema = Schema([Transcription.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}

private func audioContinuityModel() -> CloudModel {
    CloudModel(
        name: "deepgram-live",
        displayName: "deepgram-live",
        description: "Audio continuity test model",
        provider: .deepgram,
        speed: 1,
        accuracy: 1,
        isMultilingual: true,
        supportsStreaming: true,
        supportedLanguages: ["en": "English"]
    )
}

private final class AudioContinuityStreamingProvider:
    StreamingTranscriptionProvider,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let eventContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>
    private var _commitCallCount = 0

    init() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: StreamingTranscriptionEvent.self
        )
        transcriptionEvents = stream
        eventContinuation = continuation
    }

    var commitCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _commitCallCount
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        eventContinuation.yield(.sessionStarted)
    }

    func sendAudioChunk(_ data: Data) async throws {}

    func commit() async throws {
        withLock { _commitCallCount += 1 }
        eventContinuation.yield(.committed(text: "complete"))
        eventContinuation.yield(.finalized)
    }

    func disconnect() async {
        eventContinuation.finish()
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private final class AudioContinuityBatchService: TranscriptionService, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0

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
        incrementCallCount()
        return "should not upload"
    }

    private func incrementCallCount() {
        lock.lock()
        _callCount += 1
        lock.unlock()
    }
}

private enum AudioContinuityBlockingWait {
    static func wait(
        _ semaphore: DispatchSemaphore,
        timeout: DispatchTime
    ) -> DispatchTimeoutResult {
        semaphore.wait(timeout: timeout)
    }
}
