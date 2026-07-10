import FluidAudio
import Foundation
import os

/// True streaming provider backed by FluidAudio's Parakeet Unified manager.
final class FluidAudioUnifiedStreamingProvider: StreamingTranscriptionProvider, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.metrovoc.voiceink", category: "FluidAudioUnifiedStreaming")
    private var manager: StreamingUnifiedAsrManager?
    private var eventsContinuation: StreamingProviderEventRelay?

    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init() {
        let relay = StreamingProviderEventRelay()
        transcriptionEvents = relay.stream
        eventsContinuation = relay
    }

    deinit {
        eventsContinuation?.finish()
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        let manager = StreamingUnifiedAsrManager(
            encoderPrecision: FluidAudioModelManager.parakeetUnifiedPrecision
        )
        let continuation = eventsContinuation
        await manager.setPartialTranscriptCallback { partial in
            continuation?.yield(.partial(text: partial))
        }
        try await manager.loadModels()
        self.manager = manager
        eventsContinuation?.yield(.sessionStarted)
        logger.notice("Parakeet Unified streaming started for \(model.displayName, privacy: .public)")
    }

    func sendAudioChunk(_ data: Data) async throws {
        guard let manager else {
            throw StreamingTranscriptionError.notConnected
        }

        guard !data.isEmpty else { return }

        guard let buffer = PCMAudioConverter.pcmBuffer(fromPCM16Data: data) else {
            throw StreamingTranscriptionError.audioConversionFailed
        }

        try await manager.appendAudio(buffer)
        try await manager.processBufferedAudio()
    }

    func commit() async throws {
        guard let manager else {
            throw StreamingTranscriptionError.notConnected
        }

        let finalText = try await manager.finish()
        let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = TextNormalizer.shared.normalizeSentence(text)
        eventsContinuation?.yield(.committed(text: normalized))
        eventsContinuation?.yield(.finalized)
    }

    func disconnect() async {
        await manager?.cleanup()
        manager = nil
        eventsContinuation?.finish()
        logger.notice("Parakeet Unified streaming disconnected")
    }
}
