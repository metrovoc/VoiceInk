import Foundation
import LLMkit

/// AssemblyAI streaming provider wrapping `LLMkit.AssemblyAIStreamingClient`.
final class AssemblyAIStreamingProvider: StreamingTranscriptionProvider, @unchecked Sendable {

    private let client = LLMkit.AssemblyAIStreamingClient()
    private var eventsContinuation: StreamingProviderEventRelay?
    private var forwardingTask: Task<Void, Never>?
    private let customVocabulary: [String]

    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init(customVocabulary: [String]) {
        self.customVocabulary = customVocabulary
        let relay = StreamingProviderEventRelay()
        transcriptionEvents = relay.stream
        eventsContinuation = relay
    }

    deinit {
        forwardingTask?.cancel()
        eventsContinuation?.finish()
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "AssemblyAI"), !apiKey.isEmpty else {
            throw StreamingTranscriptionError.missingAPIKey
        }

        forwardingTask?.cancel()
        startEventForwarding()

        do {
            try await client.connect(
                apiKey: apiKey,
                model: model.name,
                language: language,
                prompt: transcriptionPrompt(),
                customVocabulary: customVocabulary
            )
        } catch {
            forwardingTask?.cancel()
            forwardingTask = nil
            throw mapError(error)
        }
    }

    func sendAudioChunk(_ data: Data) async throws {
        do {
            try await client.sendAudioChunk(data)
        } catch {
            throw mapError(error)
        }
    }

    func commit() async throws {
        do {
            try await client.commit()
        } catch {
            throw mapError(error)
        }
    }

    func disconnect() async {
        forwardingTask?.cancel()
        forwardingTask = nil
        await client.disconnect()
        eventsContinuation?.finish()
    }

    // MARK: - Private

    private func startEventForwarding() {
        forwardingTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.client.transcriptionEvents {
                switch event {
                case .sessionStarted:
                    self.eventsContinuation?.yield(.sessionStarted)
                case .partial(let text):
                    self.eventsContinuation?.yield(.partial(text: text))
                case .committed(let text):
                    self.eventsContinuation?.yield(.committed(text: text))
                case .finalized:
                    self.eventsContinuation?.yield(.finalized)
                case .error(let message):
                    self.eventsContinuation?.yield(.error(StreamingTranscriptionError.serverError(message)))
                }
            }
        }
    }

    private func transcriptionPrompt() -> String? {
        let prompt = UserDefaults.standard.string(forKey: "TranscriptionPrompt") ?? ""
        return prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt
    }

    private func mapError(_ error: Error) -> Error {
        guard let llmError = error as? LLMKitError else { return error }
        switch llmError {
        case .missingAPIKey:
            return StreamingTranscriptionError.missingAPIKey
        case .httpError(_, let message):
            return StreamingTranscriptionError.serverError(message)
        case .networkError(let detail):
            return StreamingTranscriptionError.connectionFailed(detail)
        case .timeout:
            return StreamingTranscriptionError.timeout
        default:
            return StreamingTranscriptionError.serverError(llmError.localizedDescription)
        }
    }
}
