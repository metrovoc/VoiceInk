import Foundation
import os

/// Encapsulates a single recording-to-transcription lifecycle (streaming or file-based).
@MainActor
protocol TranscriptionSession: AnyObject {
    /// Prepares the session. Returns an audio chunk callback for streaming, or nil for file-based.
    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)?

    /// Whether a prepared session can still be reused by the active recording.
    func canReusePreparedSession() -> Bool

    /// Called after recording stops. Returns the final transcribed text.
    func transcribe(audioURL: URL) async throws -> String

    /// Cancel the session and clean up resources.
    func cancel()
}

// MARK: - File-Based Session

/// File-based session: records to file, uploads after stop.
@MainActor
final class FileTranscriptionSession: TranscriptionSession {
    private let service: TranscriptionService
    private var model: (any TranscriptionModel)?
    private var context: TranscriptionRequestContext = .currentDefaults

    init(service: TranscriptionService) {
        self.service = service
    }

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? {
        self.model = configuration.model
        self.context = configuration.requestContext
        return nil
    }

    func canReusePreparedSession() -> Bool {
        true
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let model = model else {
            throw VoiceInkEngineError.transcriptionFailed
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

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? {
        let model = configuration.model
        let context = configuration.requestContext

        startTask?.cancel()
        self.model = model
        self.context = context
        self.streamingFailed = false
        self.isCancelled = false
        logger.notice("Streaming session prepare model=\(model.displayName, privacy: .public)")

        let start = Date()
        let service = streamingService
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

        let callback: (Data) -> Void = { data in
            service.sendAudioChunk(data)
        }

        logger.notice("Streaming session audio callback ready before connection model=\(model.displayName, privacy: .public)")
        return callback
    }

    func canReusePreparedSession() -> Bool {
        !streamingFailed && !isCancelled
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let model = model else {
            throw VoiceInkEngineError.transcriptionFailed
        }

        if !streamingFailed {
            do {
                try await waitForStreamingStartIfNeeded()
                let start = Date()
                logger.notice("Streaming stop/transcribe started model=\(model.displayName, privacy: .public)")
                let text = try await streamingService.stopAndGetFinalText()
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    logger.notice("Streaming completed with empty transcript elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s")
                    return ""
                }
                logger.notice("Streaming transcript received elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s chars=\(text.count, privacy: .public)")
                return text
            } catch {
                logger.error("❌ Streaming failed, falling back to batch: \(error, privacy: .public)")
                streamingService.cancel()
            }
        } else {
            streamingService.cancel()
        }

        let fallbackStart = Date()
        logger.notice("Using batch fallback for \(model.displayName, privacy: .public) file=\(audioURL.lastPathComponent, privacy: .public)")
        let text = try await fallbackService.transcribe(audioURL: audioURL, model: model, context: context)
        logger.notice("Batch fallback completed elapsed=\(Date().timeIntervalSince(fallbackStart), format: .fixed(precision: 3), privacy: .public)s chars=\(text.count, privacy: .public)")
        return text
    }

    func cancel() {
        isCancelled = true
        startTask?.cancel()
        startTask = nil
        streamingService.cancel()
    }

    private func waitForStreamingStartIfNeeded() async throws {
        guard let startTask else { return }
        defer { self.startTask = nil }

        let timeoutNanoseconds = streamingStartTimeoutNanoseconds
        let started = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await startTask.value
                return true
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                return false
            }

            let result = try await group.next() ?? false
            if !result {
                isCancelled = true
                startTask.cancel()
                streamingService.cancel()
                streamingFailed = true
            }
            group.cancelAll()
            return result
        }

        guard started else {
            logger.error("❌ Timed out waiting for streaming session to become ready")
            throw StreamingTranscriptionError.timeout
        }
    }
}
