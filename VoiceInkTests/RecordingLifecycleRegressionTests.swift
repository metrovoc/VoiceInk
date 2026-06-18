import Foundation
import SwiftData
import Testing
@testable import VoiceInk_CE

struct RecordingLifecycleRegressionTests {
    @Test func recordingShortcutPolicyRejectsOnlyNonInteractiveStates() {
        #expect(RecordingInteractionPolicy.canProcessRecordingShortcut(when: .idle))
        #expect(RecordingInteractionPolicy.canProcessRecordingShortcut(when: .recording))

        for state in [RecordingState.starting, .transcribing, .enhancing, .busy] {
            #expect(!RecordingInteractionPolicy.canProcessRecordingShortcut(when: state))
        }
    }

    @Test func recorderTogglePolicyNeverStopsDuringStartup() {
        #expect(RecordingInteractionPolicy.toggleAction(isRecorderVisible: false, state: .idle) == .start)
        #expect(RecordingInteractionPolicy.toggleAction(isRecorderVisible: true, state: .recording) == .stopRecording)
        #expect(RecordingInteractionPolicy.toggleAction(isRecorderVisible: true, state: .idle) == .cancelIdleRecorder)
        #expect(
            RecordingInteractionPolicy.toggleAction(
                isRecorderVisible: true,
                state: .idle,
                canSendAssistantFollowUp: true
            ) == .startAssistantFollowUp
        )

        #expect(RecordingInteractionPolicy.toggleAction(isRecorderVisible: false, state: .starting) == .ignore)
        #expect(RecordingInteractionPolicy.toggleAction(isRecorderVisible: true, state: .starting) == .ignore)

        for state in [RecordingState.transcribing, .enhancing, .busy] {
            #expect(RecordingInteractionPolicy.toggleAction(isRecorderVisible: false, state: state) == .ignore)
            #expect(RecordingInteractionPolicy.toggleAction(isRecorderVisible: true, state: state) == .ignore)
        }
    }

    @MainActor
    @Test func streamingServiceDrainsBufferedAudioBeforeCommit() async throws {
        let provider = FakeStreamingProvider(commitEvent: .committed(text: "final text"))
        let service = try StreamingTranscriptionService(
            modelContext: makeModelContext(),
            providerFactory: { _, _, _ in provider },
            finalCommitTimeoutNanoseconds: 200_000_000
        )

        try await service.startStreaming(
            model: makeCloudModel(name: "deepgram-live", provider: .deepgram),
            context: TranscriptionRequestContext(language: "en", prompt: nil)
        )

        let chunks = [Data([0x01]), Data([0x02, 0x03]), Data([0x04])]
        for chunk in chunks {
            service.sendAudioChunk(chunk)
        }

        let text = try await service.stopAndGetFinalText()

        #expect(text == "final text")
        #expect(provider.sentChunks == chunks)
        #expect(provider.sentChunkCountAtCommit == chunks.count)
        #expect(provider.commitCallCount == 1)
        #expect(provider.disconnectCallCount == 1)
    }

    @MainActor
    @Test func streamingServiceTimesOutWhenFinalCommitNeverArrives() async throws {
        let provider = FakeStreamingProvider(commitEvent: nil)
        let service = try StreamingTranscriptionService(
            modelContext: makeModelContext(),
            providerFactory: { _, _, _ in provider },
            finalCommitTimeoutNanoseconds: 20_000_000
        )

        try await service.startStreaming(
            model: makeCloudModel(name: "deepgram-live", provider: .deepgram),
            context: TranscriptionRequestContext(language: "en", prompt: nil)
        )

        do {
            _ = try await service.stopAndGetFinalText()
            Issue.record("Expected stopAndGetFinalText to time out when no final commit event arrives")
        } catch StreamingTranscriptionError.timeout {
            #expect(provider.commitCallCount == 1)
            #expect(provider.disconnectCallCount == 1)
        } catch {
            Issue.record("Expected StreamingTranscriptionError.timeout, got \(error)")
        }
    }

    @MainActor
    @Test func streamingServiceTimesOutWhenFinalCommitAckNeverArrivesAfterPriorCommit() async throws {
        let provider = FakeStreamingProvider(commitEvent: nil)
        let service = try StreamingTranscriptionService(
            modelContext: makeModelContext(),
            providerFactory: { _, _, _ in provider },
            finalCommitTimeoutNanoseconds: 20_000_000
        )

        try await service.startStreaming(
            model: makeCloudModel(name: "deepgram-live", provider: .deepgram),
            context: TranscriptionRequestContext(language: "en", prompt: nil)
        )
        provider.emit(.committed(text: "already committed"))
        try await Task.sleep(nanoseconds: 20_000_000)

        do {
            _ = try await service.stopAndGetFinalText()
            Issue.record("Expected final commit ack timeout even when older committed text exists")
        } catch StreamingTranscriptionError.timeout {
            #expect(provider.commitCallCount == 1)
            #expect(provider.disconnectCallCount == 1)
        } catch {
            Issue.record("Expected StreamingTranscriptionError.timeout, got \(error)")
        }
    }

    @MainActor
    @Test func streamingSessionWaitsForStreamingStartBeforeReturningAudioCallback() async throws {
        let streamingService = DelayedStartStreamingService()
        let fallbackService = FakeBatchTranscriptionService(result: "batch transcript")
        let streamingModel = makeCloudModel(name: "deepgram-live", provider: .deepgram)
        let session = StreamingTranscriptionSession(
            streamingService: streamingService,
            fallbackService: fallbackService
        )

        let prepareTask = Task { @MainActor in
            try await session.prepare(
                configuration: TranscriptionRuntimeConfiguration(
                    mode: nil,
                    model: streamingModel,
                    language: "en",
                    isRealtimeEnabled: true
                )
            )
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(streamingService.startCallCount == 1)
        #expect(streamingService.sentChunks.isEmpty)

        streamingService.releaseStart()
        let preparedCallback = try await prepareTask.value
        let callback = try #require(preparedCallback)
        let chunk = Data([0x2A])
        callback(chunk)

        #expect(streamingService.sentChunks == [chunk])
    }

    @MainActor
    @Test func streamingServiceFailsWithoutCommitWhenAudioSendFails() async throws {
        let provider = FakeStreamingProvider(
            commitEvent: .committed(text: "should not commit"),
            sendError: StreamingTranscriptionError.connectionFailed("dead socket")
        )
        let service = try StreamingTranscriptionService(
            modelContext: makeModelContext(),
            providerFactory: { _, _, _ in provider },
            finalCommitTimeoutNanoseconds: 200_000_000
        )

        try await service.startStreaming(
            model: makeCloudModel(name: "deepgram-live", provider: .deepgram),
            context: TranscriptionRequestContext(language: "en", prompt: nil)
        )

        service.sendAudioChunk(Data([0x01]))

        do {
            _ = try await service.stopAndGetFinalText()
            Issue.record("Expected stopAndGetFinalText to fail when sending audio fails")
        } catch StreamingTranscriptionError.connectionFailed(let message) {
            #expect(message == "dead socket")
            #expect(provider.commitCallCount == 0)
            #expect(provider.disconnectCallCount == 1)
        } catch {
            Issue.record("Expected StreamingTranscriptionError.connectionFailed, got \(error)")
        }
    }

    @MainActor
    @Test func streamingServiceFailsWhenProviderErrorsAfterCommitEvent() async throws {
        let provider = FakeStreamingProvider(
            commitEvents: [
                .error(StreamingTranscriptionError.serverError("commit failed"))
            ]
        )
        let service = try StreamingTranscriptionService(
            modelContext: makeModelContext(),
            providerFactory: { _, _, _ in provider },
            finalCommitTimeoutNanoseconds: 200_000_000
        )

        try await service.startStreaming(
            model: makeCloudModel(name: "deepgram-live", provider: .deepgram),
            context: TranscriptionRequestContext(language: "en", prompt: nil)
        )
        provider.emit(.committed(text: "partial final"))
        try await Task.sleep(nanoseconds: 20_000_000)

        do {
            _ = try await service.stopAndGetFinalText()
            Issue.record("Expected provider error after commit event to fail the streaming session")
        } catch StreamingTranscriptionError.serverError(let message) {
            #expect(message == "commit failed")
            #expect(provider.disconnectCallCount == 1)
        } catch {
            Issue.record("Expected StreamingTranscriptionError.serverError, got \(error)")
        }
    }

    @MainActor
    @Test func streamingSessionFallsBackToBatchWhenStreamingReturnsEmptyText() async throws {
        let streamingService = FakeStreamingService(stopResult: .success("  \n"))
        let fallbackService = FakeBatchTranscriptionService(result: "batch transcript")
        let streamingModel = makeCloudModel(name: "deepgram-live", provider: .deepgram)
        let session = StreamingTranscriptionSession(
            streamingService: streamingService,
            fallbackService: fallbackService
        )

        let preparedCallback = try await session.prepare(
            configuration: TranscriptionRuntimeConfiguration(
                mode: nil,
                model: streamingModel,
                language: "en",
                isRealtimeEnabled: true
            )
        )
        let callback = try #require(preparedCallback)
        let chunk = Data([0x2A])
        callback(chunk)

        let text = try await session.transcribe(audioURL: URL(fileURLWithPath: "/tmp/voiceink-test.wav"))

        #expect(text == "batch transcript")
        #expect(streamingService.sentChunks == [chunk])
        #expect(streamingService.stopCallCount == 1)
        #expect(streamingService.cancelCallCount == 1)
        #expect(fallbackService.transcribeCallCount == 1)
        #expect(fallbackService.modelNames == ["deepgram-live"])
    }

    @MainActor
    @Test func streamingSessionFallsBackToBatchWhenStreamingStopTimesOut() async throws {
        let streamingService = FakeStreamingService(stopResult: .failure(StreamingTranscriptionError.timeout))
        let fallbackService = FakeBatchTranscriptionService(result: "batch transcript")
        let streamingModel = makeCloudModel(name: "deepgram-live", provider: .deepgram)
        let session = StreamingTranscriptionSession(
            streamingService: streamingService,
            fallbackService: fallbackService
        )

        _ = try await session.prepare(
            configuration: TranscriptionRuntimeConfiguration(
                mode: nil,
                model: streamingModel,
                language: "en",
                isRealtimeEnabled: true
            )
        )

        let text = try await session.transcribe(audioURL: URL(fileURLWithPath: "/tmp/voiceink-test.wav"))

        #expect(text == "batch transcript")
        #expect(streamingService.stopCallCount == 1)
        #expect(streamingService.cancelCallCount == 1)
        #expect(fallbackService.transcribeCallCount == 1)
        #expect(fallbackService.modelNames == ["deepgram-live"])
    }
}

@MainActor
private func makeModelContext() throws -> ModelContext {
    let schema = Schema([Transcription.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return container.mainContext
}

private func makeCloudModel(name: String, provider: ModelProvider) -> CloudModel {
    CloudModel(
        name: name,
        displayName: name,
        description: "Test model",
        provider: provider,
        speed: 1,
        accuracy: 1,
        isMultilingual: true,
        supportsStreaming: true,
        supportedLanguages: ["en": "English"]
    )
}

private final class FakeStreamingProvider: StreamingTranscriptionProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _sentChunks: [Data] = []
    private var _sentChunkCountAtCommit: Int?
    private var _commitCallCount = 0
    private var _disconnectCallCount = 0
    private let commitEvents: [StreamingTranscriptionEvent]
    private let sendError: Error?
    private let eventContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init(commitEvent: StreamingTranscriptionEvent?, sendError: Error? = nil) {
        self.commitEvents = commitEvent.map { [$0] } ?? []
        self.sendError = sendError
        let (stream, continuation) = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
        self.transcriptionEvents = stream
        self.eventContinuation = continuation
    }

    init(commitEvents: [StreamingTranscriptionEvent], sendError: Error? = nil) {
        self.commitEvents = commitEvents
        self.sendError = sendError
        let (stream, continuation) = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
        self.transcriptionEvents = stream
        self.eventContinuation = continuation
    }

    var sentChunks: [Data] {
        withLock { _sentChunks }
    }

    var sentChunkCountAtCommit: Int? {
        withLock { _sentChunkCountAtCommit }
    }

    var commitCallCount: Int {
        withLock { _commitCallCount }
    }

    var disconnectCallCount: Int {
        withLock { _disconnectCallCount }
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        eventContinuation.yield(.sessionStarted)
    }

    func sendAudioChunk(_ data: Data) async throws {
        if let sendError {
            throw sendError
        }
        withLock { _sentChunks.append(data) }
    }

    func commit() async throws {
        withLock {
            _commitCallCount += 1
            _sentChunkCountAtCommit = _sentChunks.count
        }
        for commitEvent in commitEvents {
            eventContinuation.yield(commitEvent)
        }
    }

    func emit(_ event: StreamingTranscriptionEvent) {
        eventContinuation.yield(event)
    }

    func disconnect() async {
        withLock { _disconnectCallCount += 1 }
        eventContinuation.finish()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class DelayedStartStreamingService: StreamingTranscriptionServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var _sentChunks: [Data] = []
    private var _startCallCount = 0

    var startCallCount: Int {
        withLock { _startCallCount }
    }

    var sentChunks: [Data] {
        withLock { _sentChunks }
    }

    @MainActor
    var isActive: Bool { true }

    @MainActor
    func startStreaming(model: any TranscriptionModel, context: TranscriptionRequestContext) async throws {
        withLock { _startCallCount += 1 }
        await withCheckedContinuation { continuation in
            withLock { startContinuation = continuation }
        }
    }

    nonisolated func sendAudioChunk(_ data: Data) {
        withLock { _sentChunks.append(data) }
    }

    @MainActor
    func stopAndGetFinalText() async throws -> String {
        "streaming transcript"
    }

    @MainActor
    func cancel() {
        releaseStart()
    }

    func releaseStart() {
        let continuation = withLock { () -> CheckedContinuation<Void, Never>? in
            let continuation = startContinuation
            startContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class FakeStreamingService: StreamingTranscriptionServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var _sentChunks: [Data] = []
    private var _stopCallCount = 0
    private var _cancelCallCount = 0
    private let stopResult: Result<String, Error>

    init(stopResult: Result<String, Error>) {
        self.stopResult = stopResult
    }

    var sentChunks: [Data] {
        withLock { _sentChunks }
    }

    var stopCallCount: Int {
        withLock { _stopCallCount }
    }

    var cancelCallCount: Int {
        withLock { _cancelCallCount }
    }

    @MainActor
    var isActive: Bool { true }

    @MainActor
    func startStreaming(model: any TranscriptionModel, context: TranscriptionRequestContext) async throws {}

    nonisolated func sendAudioChunk(_ data: Data) {
        withLock { _sentChunks.append(data) }
    }

    @MainActor
    func stopAndGetFinalText() async throws -> String {
        withLock { _stopCallCount += 1 }
        return try stopResult.get()
    }

    @MainActor
    func cancel() {
        withLock { _cancelCallCount += 1 }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class FakeBatchTranscriptionService: TranscriptionService, @unchecked Sendable {
    private let lock = NSLock()
    private var _modelNames: [String] = []
    private let result: String

    init(result: String) {
        self.result = result
    }

    var transcribeCallCount: Int {
        withLock { _modelNames.count }
    }

    var modelNames: [String] {
        withLock { _modelNames }
    }

    func transcribe(
        audioURL: URL,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) async throws -> String {
        withLock { _modelNames.append(model.name) }
        return result
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
