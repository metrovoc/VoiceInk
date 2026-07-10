import Foundation
import os

private final class StreamingStartTimeoutRace: @unchecked Sendable {
    private let lock = NSLock()
    private var isResolved = false
    private var timeoutTask: Task<Void, Never>?

    func installTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        if isResolved {
            lock.unlock()
            task.cancel()
        } else {
            timeoutTask = task
            lock.unlock()
        }
    }

    @discardableResult
    func resolve(
        _ continuation: CheckedContinuation<Void, Error>,
        with result: Result<Void, Error>
    ) -> Bool {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return false
        }
        isResolved = true
        let timeoutTask = timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
        return true
    }
}

/// Encapsulates a single recording-to-transcription lifecycle (streaming or file-based).
@MainActor
protocol TranscriptionSession: AnyObject {
    /// Prepares the session. Returns an audio chunk callback for streaming, or nil for file-based.
    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> RecordingAudioChunkHandler?

    /// Whether a prepared session can still be reused by the active recording.
    func canReusePreparedSession() -> Bool

    /// Binds the cross-layer monotonic trace before realtime connection work.
    func setPerformanceTrace(_ trace: RealtimePerformanceTrace?)

    /// Binds the per-recording hardware continuity token before preparation.
    /// File and streaming sessions share the same immutable recording owner.
    func setAudioContinuity(_ continuity: RecordingAudioContinuity?)

    /// Starts provider finalization without waiting for the recorder file or
    /// batch fallback. Repeated calls must reuse the same operation.
    func requestFinalization(trace: RealtimePerformanceTrace?)

    /// Called after recording stops. Returns the final transcribed text.
    func transcribe(audioURL: URL) async throws -> String

    /// Cancel the session and clean up resources.
    func cancel()
}

extension TranscriptionSession {
    func setPerformanceTrace(_ trace: RealtimePerformanceTrace?) {}

    func setAudioContinuity(_ continuity: RecordingAudioContinuity?) {}

    func requestFinalization(trace: RealtimePerformanceTrace?) {}

    /// Source-compatible overload for call sites that have a performance trace.
    func prepare(
        configuration: TranscriptionRuntimeConfiguration,
        trace: RealtimePerformanceTrace?
    ) async throws -> RecordingAudioChunkHandler? {
        setPerformanceTrace(trace)
        return try await prepare(configuration: configuration)
    }
}

// MARK: - File-Based Session

/// File-based session: records to file, uploads after stop.
@MainActor
final class FileTranscriptionSession: TranscriptionSession {
    private let service: TranscriptionService
    private var model: (any TranscriptionModel)?
    private var context: TranscriptionRequestContext = .currentDefaults
    private var audioContinuity: RecordingAudioContinuity?

    init(service: TranscriptionService) {
        self.service = service
    }

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> RecordingAudioChunkHandler? {
        self.model = configuration.model
        self.context = configuration.requestContext
        return nil
    }

    func canReusePreparedSession() -> Bool {
        true
    }

    func setAudioContinuity(_ continuity: RecordingAudioContinuity?) {
        audioContinuity = continuity
        continuity?.disableStreamingTracking()
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let model = model else {
            throw VoiceInkEngineError.transcriptionFailed
        }
        if let audioContinuity {
            await audioContinuity.waitUntilCaptureSealed()
            let snapshot = audioContinuity.snapshot()
            if snapshot.hasFileDiscontinuity {
                throw RecordingAudioIntegrityError.incompleteFile(
                    droppedChunks: snapshot.fileDroppedChunks,
                    droppedBytes: snapshot.fileDroppedBytes,
                    writeErrors: snapshot.fileWriteErrors
                )
            }
        }
        return try await service.transcribe(audioURL: audioURL, model: model, context: context)
    }

    func cancel() {
        // No-op for file-based transcription
    }
}

// MARK: - Streaming Session

/// Streaming session with file-based upload fallback for streaming transport failures.
@MainActor
final class StreamingTranscriptionSession: TranscriptionSession {
    private let streamingService: any StreamingTranscriptionServicing
    private let fallbackService: TranscriptionService
    private var model: (any TranscriptionModel)?
    private var context: TranscriptionRequestContext = .currentDefaults
    private var streamingFailed = false
    private var isCancelled = false
    private var startTask: Task<Void, Error>?
    private var finalizationTask: Task<String, Error>?
    private var performanceTrace: RealtimePerformanceTrace?
    private var audioContinuity: RecordingAudioContinuity?
    private let streamingStartTimeoutNanoseconds: UInt64
    private let logger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "StreamingTranscriptionSession")

    init(
        streamingService: any StreamingTranscriptionServicing,
        fallbackService: TranscriptionService,
        streamingStartTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.streamingService = streamingService
        self.fallbackService = fallbackService
        self.streamingStartTimeoutNanoseconds = streamingStartTimeoutNanoseconds
    }

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> RecordingAudioChunkHandler? {
        let model = configuration.model
        let context = configuration.requestContext

        startTask?.cancel()
        finalizationTask?.cancel()
        finalizationTask = nil
        self.model = model
        self.context = context
        self.streamingFailed = false
        self.isCancelled = false
        if let continuityService = streamingService as? any StreamingAudioContinuityBinding {
            continuityService.bindAudioContinuity(audioContinuity)
        }
        if let tracingService = streamingService as? any StreamingPerformanceTracing {
            tracingService.setPerformanceTrace(performanceTrace)
        }
        logger.notice("Streaming session prepare model=\(model.displayName, privacy: .public)")

        let start = Date()
        let service = streamingService
        if let immediateService = service as? any StreamingImmediateStarting {
            // Provider creation and core submission happen synchronously here,
            // before the audio callback is returned. A stop in the same run-loop
            // turn therefore cannot overtake connection setup.
            let submittedTask = immediateService.requestStartTask(
                model: model,
                context: context
            )
            startTask = submittedTask
            Task { @MainActor [weak self, service, model] in
                do {
                    try await submittedTask.value
                    guard let self, !self.isCancelled else {
                        service.cancel()
                        return
                    }
                    self.logger.notice("Streaming session ready model=\(model.displayName, privacy: .public) elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s")
                } catch is CancellationError {
                    service.cancel()
                } catch {
                    guard let self, !self.isCancelled else { return }
                    self.streamingFailed = true
                    self.logger.error("❌ Failed to prepare streaming session: \(error.localizedDescription, privacy: .public)")
                }
            }
        } else {
            startTask = Task { @MainActor [weak self, service, model, context] in
                guard let self else { return }

                do {
                    try Task.checkCancellation()
                    guard !self.isCancelled else {
                        service.cancel()
                        throw CancellationError()
                    }
                    try await service.startStreaming(model: model, context: context)
                    guard !self.isCancelled else {
                        service.cancel()
                        throw CancellationError()
                    }
                    self.logger.notice("Streaming session ready model=\(model.displayName, privacy: .public) elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s")
                } catch is CancellationError {
                    service.cancel()
                    throw CancellationError()
                } catch {
                    guard !self.isCancelled else {
                        service.cancel()
                        throw CancellationError()
                    }
                    self.streamingFailed = true
                    let desc = error.localizedDescription
                    self.logger.error("❌ Failed to prepare streaming session: \(desc, privacy: .public)")
                    throw error
                }
            }
        }

        let callback: RecordingAudioChunkHandler = { data in
            service.sendAudioChunk(data)
        }

        logger.notice("Streaming session audio callback ready before connection model=\(model.displayName, privacy: .public)")
        return callback
    }

    func canReusePreparedSession() -> Bool {
        !streamingFailed && !isCancelled
    }

    func setPerformanceTrace(_ trace: RealtimePerformanceTrace?) {
        performanceTrace = trace
        if let tracingService = streamingService as? any StreamingPerformanceTracing {
            tracingService.setPerformanceTrace(trace)
        }
    }

    func setAudioContinuity(_ continuity: RecordingAudioContinuity?) {
        audioContinuity = continuity
        continuity?.enableStreamingTracking()
        if let continuityService = streamingService as? any StreamingAudioContinuityBinding {
            continuityService.bindAudioContinuity(continuity)
        }
    }

    func requestFinalization(trace: RealtimePerformanceTrace?) {
        if let trace {
            setPerformanceTrace(trace)
        }
        guard finalizationTask == nil, !streamingFailed, !isCancelled else { return }

        if let immediateService = streamingService as? any StreamingImmediateFinalizing,
           let startTask {
            let timeout = streamingStartTimeoutNanoseconds
            finalizationTask = Task.detached(priority: .userInitiated) {
                try await Self.awaitSubmittedStart(startTask, timeoutNanoseconds: timeout)
                return try await immediateService.requestFinalizationTask().value
            }
            return
        }

        // Compatibility path for lightweight service doubles.
        finalizationTask = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.waitForStreamingStartIfNeeded()
            return try await self.streamingService.stopAndGetFinalText()
        }
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let model = model else {
            throw VoiceInkEngineError.transcriptionFailed
        }

        if !streamingFailed {
            do {
                requestFinalization(trace: performanceTrace)
                guard let finalizationTask else {
                    throw StreamingTranscriptionError.notConnected
                }
                let start = Date()
                logger.notice("Streaming stop/transcribe started model=\(model.displayName, privacy: .public)")
                let text = try await finalizationTask.value
                try await validateHardwareStreamingContinuity()
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    logger.notice("Streaming completed with empty transcript elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s")
                    return ""
                }
                logger.notice("Streaming transcript received elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s chars=\(text.count, privacy: .public)")
                return text
            } catch {
                streamingService.cancel()
                // Cancellation is a terminal user decision, never a transport
                // failure. Uploading the recorded file after Cancel would both
                // violate intent and keep doing expensive work invisibly.
                if isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                logger.error("❌ Streaming failed, falling back to batch: \(error, privacy: .public)")
            }
        } else {
            streamingService.cancel()
        }

        try await validateFileContinuityForFallback()
        let fallbackStart = Date()
        logger.notice("Using batch fallback for \(model.displayName, privacy: .public) file=\(audioURL.lastPathComponent, privacy: .public)")
        let text = try await fallbackService.transcribe(audioURL: audioURL, model: model, context: context)
        logger.notice("Batch fallback completed elapsed=\(Date().timeIntervalSince(fallbackStart), format: .fixed(precision: 3), privacy: .public)s chars=\(text.count, privacy: .public)")
        return text
    }

    private func validateHardwareStreamingContinuity() async throws {
        guard let audioContinuity else { return }
        await audioContinuity.waitUntilCaptureSealed()
        let snapshot = audioContinuity.snapshot()
        guard snapshot.hasStreamingDiscontinuity else { return }
        throw StreamingTranscriptionError.audioDropped(
            chunks: snapshot.streamingDroppedChunks,
            bytes: snapshot.streamingDroppedBytes
        )
    }

    private func validateFileContinuityForFallback() async throws {
        guard let audioContinuity else { return }
        await audioContinuity.waitUntilCaptureSealed()
        let snapshot = audioContinuity.snapshot()
        guard snapshot.hasFileDiscontinuity else { return }
        throw RecordingAudioIntegrityError.incompleteFile(
            droppedChunks: snapshot.fileDroppedChunks,
            droppedBytes: snapshot.fileDroppedBytes,
            writeErrors: snapshot.fileWriteErrors
        )
    }

    func cancel() {
        isCancelled = true
        startTask?.cancel()
        startTask = nil
        finalizationTask?.cancel()
        finalizationTask = nil
        streamingService.cancel()
    }

    private func waitForStreamingStartIfNeeded() async throws {
        guard let startTask else { return }
        defer { self.startTask = nil }

        do {
            try await Self.awaitSubmittedStart(
                startTask,
                timeoutNanoseconds: streamingStartTimeoutNanoseconds
            )
        } catch StreamingTranscriptionError.timeout {
            streamingService.cancel()
            streamingFailed = true
            logger.error("❌ Timed out waiting for streaming session to become ready")
            throw StreamingTranscriptionError.timeout
        } catch {
            throw error
        }
    }

    private nonisolated static func awaitSubmittedStart(
        _ startTask: Task<Void, Error>,
        timeoutNanoseconds: UInt64
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let race = StreamingStartTimeoutRace()

            Task.detached(priority: .userInitiated) {
                do {
                    try await startTask.value
                    race.resolve(continuation, with: .success(()))
                } catch {
                    race.resolve(continuation, with: .failure(error))
                }
            }

            let timeoutTask = Task.detached(priority: .userInitiated) {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                if race.resolve(
                    continuation,
                    with: .failure(StreamingTranscriptionError.timeout)
                ) {
                    startTask.cancel()
                }
            }
            race.installTimeoutTask(timeoutTask)
        }
    }
}
