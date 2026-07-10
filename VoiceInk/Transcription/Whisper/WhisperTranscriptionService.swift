import Foundation
import AVFoundation
import os

/// Prevents two requests from mutating the same hot whisper context while an
/// async inference operation is suspended. Actor isolation alone is reentrant
/// and therefore does not provide this whole-operation guarantee.
actor WhisperTranscriptionOperationGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var waiterHead = 0

    func run<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async rethrows -> Value {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        guard waiterHead < waiters.count else {
            waiters.removeAll(keepingCapacity: true)
            waiterHead = 0
            isHeld = false
            return
        }
        let waiter = waiters[waiterHead]
        waiterHead += 1
        if waiterHead == waiters.count {
            waiters.removeAll(keepingCapacity: true)
            waiterHead = 0
        }
        waiter.resume()
    }
}

actor WhisperTranscriptionService: TranscriptionService {

    private let logger = Logger(subsystem: "com.metrovoc.voiceink", category: "WhisperTranscriptionService")
    private let modelsDirectory: URL
    private weak var modelProvider: (any WhisperModelProvider)?
    private let operationGate = WhisperTranscriptionOperationGate()

    init(modelsDirectory: URL, modelProvider: (any WhisperModelProvider)? = nil) {
        self.modelsDirectory = modelsDirectory
        self.modelProvider = modelProvider
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws -> String {
        try await operationGate.run { [self] in
            try Task.checkCancellation()
            return try await transcribeExclusively(
                audioURL: audioURL,
                model: model,
                requestContext: context
            )
        }
    }

    private func transcribeExclusively(
        audioURL: URL,
        model: any TranscriptionModel,
        requestContext: TranscriptionRequestContext
    ) async throws -> String {
        guard model.provider == .whisper else {
            throw VoiceInkEngineError.modelLoadFailed
        }

        logger.notice("Initiating local transcription for model: \(model.displayName, privacy: .public)")

        // Join the manager's generation-safe shared load. Very short
        // recordings can finish while prewarm is still running; they must not
        // create a second native context or let an older load win afterward.
        let whisperContext: WhisperContext
        if let provider = modelProvider {
            do {
                whisperContext = try await provider.context(forModelNamed: model.name)
                logger.notice("Using shared model context: \(model.name, privacy: .public)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.error("❌ Failed to load shared model: \(model.name, privacy: .public) - \(error, privacy: .public)")
                throw VoiceInkEngineError.modelLoadFailed
            }
        } else {
            let modelURL = modelsDirectory.appendingPathComponent("\(model.name).bin")
            guard FileManager.default.fileExists(atPath: modelURL.path) else {
                logger.error("❌ Model file not found for: \(model.name, privacy: .public)")
                throw VoiceInkEngineError.modelLoadFailed
            }

            logger.notice("Loading model: \(model.name, privacy: .public)")
            do {
                whisperContext = try await WhisperContext.createContext(path: modelURL.path)
            } catch {
                logger.error("❌ Failed to load model: \(model.name, privacy: .public) - \(error, privacy: .public)")
                throw VoiceInkEngineError.modelLoadFailed
            }
        }

        // Read audio data
        let data = try readAudioSamples(audioURL)

        // Set prompt
        await whisperContext.setLanguage(requestContext.language)
        await whisperContext.setPrompt(requestContext.prompt ?? "")

        // Transcribe
        let success = await whisperContext.fullTranscribe(samples: data)

        guard success else {
            logger.error("❌ Core transcription engine failed (whisper_full).")
            throw VoiceInkEngineError.whisperCoreFailed
        }

        let text = await whisperContext.getTranscription()

        logger.notice("Whisper transcription completed successfully.")

        // Only release resources if we created a new context (not using the shared one)
        if modelProvider == nil {
            await whisperContext.releaseResources()
        }

        return text
    }

    private func readAudioSamples(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        let floats = stride(from: 44, to: data.count, by: 2).map {
            return data[$0..<$0 + 2].withUnsafeBytes {
                let short = Int16(littleEndian: $0.load(as: Int16.self))
                return max(-1.0, min(Float(short) / 32767.0, 1.0))
            }
        }
        return floats
    }
}
