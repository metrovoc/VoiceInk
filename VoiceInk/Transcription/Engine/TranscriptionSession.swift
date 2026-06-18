import Foundation
import os

/// Encapsulates a single recording-to-transcription lifecycle (streaming or file-based).
@MainActor
protocol TranscriptionSession: AnyObject {
    /// Prepares the session. Returns an audio chunk callback for streaming, or nil for file-based.
    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)?

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

/// Streaming session with automatic fallback to file-based upload on failure.
@MainActor
final class StreamingTranscriptionSession: TranscriptionSession {
    private let streamingService: any StreamingTranscriptionServicing
    private let fallbackService: TranscriptionService
    private var model: (any TranscriptionModel)?
    private var context: TranscriptionRequestContext = .currentDefaults
    private var streamingFailed = false
    private var isCancelled = false
    private let logger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "StreamingTranscriptionSession")

    init(streamingService: any StreamingTranscriptionServicing, fallbackService: TranscriptionService) {
        self.streamingService = streamingService
        self.fallbackService = fallbackService
    }

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? {
        let model = configuration.model
        let context = configuration.requestContext

        self.model = model
        self.context = context
        self.streamingFailed = false
        self.isCancelled = false
        logger.notice("Streaming session prepare model=\(model.displayName, privacy: .public)")

        let start = Date()
        do {
            try await streamingService.startStreaming(model: model, context: context)
            guard !isCancelled else {
                streamingService.cancel()
                throw CancellationError()
            }
            logger.notice("Streaming session ready model=\(model.displayName, privacy: .public) elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s")
        } catch is CancellationError {
            streamingService.cancel()
            throw CancellationError()
        } catch {
            guard !isCancelled else {
                streamingService.cancel()
                throw CancellationError()
            }
            streamingFailed = true
            let desc = error.localizedDescription
            logger.error("❌ Failed to prepare streaming session: \(desc, privacy: .public)")
            throw error
        }

        let service = streamingService
        let callback: (Data) -> Void = { data in
            service.sendAudioChunk(data)
        }

        return callback
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let model = model else {
            throw VoiceInkEngineError.transcriptionFailed
        }

        if !streamingFailed {
            do {
                let start = Date()
                logger.notice("Streaming stop/transcribe started model=\(model.displayName, privacy: .public)")
                let text = try await streamingService.stopAndGetFinalText()
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw StreamingTranscriptionError.emptyTranscript
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
        streamingService.cancel()
    }
}
