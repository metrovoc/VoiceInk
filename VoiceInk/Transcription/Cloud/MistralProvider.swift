import Foundation
import SwiftData
import LLMkit

struct MistralProvider: CloudProvider {
    let modelProvider: ModelProvider = .mistral
    let providerKey: String = "Mistral"
    let languageCodes: [String]? = VoxtralLanguages.fileCodes
    let includesAutoDetect: Bool = true

    var models: [CloudModel] {
        [
            CloudModel(
                name: "voxtral-small-transcribe-3-0",
                displayName: "Voxtral Small Transcribe 3",
                description: "Mistral's highest-accuracy Voxtral 3 model for recorded audio",
                provider: .mistral,
                speed: 0.92,
                accuracy: 0.99,
                isMultilingual: true,
                supportedLanguages: VoxtralLanguages.file
            ),
            CloudModel(
                name: "voxtral-mini-transcribe-3-0",
                displayName: "Voxtral Mini Transcribe 3",
                description: "Fast, lower-cost Voxtral 3 transcription for recorded audio",
                provider: .mistral,
                speed: 0.99,
                accuracy: 0.97,
                isMultilingual: true,
                supportedLanguages: VoxtralLanguages.file
            ),
            CloudModel(
                name: "voxtral-mini-transcribe-realtime-3-0",
                displayName: "Voxtral Mini Realtime 3",
                description: "Live Voxtral 3 transcription with Mini Transcribe 3 fallback",
                provider: .mistral,
                speed: 0.99,
                accuracy: 0.97,
                isMultilingual: true,
                supportsStreaming: true,
                supportedLanguages: VoxtralLanguages.realtime
            ),
        ]
    }

    func transcribe(audioData: Data, fileName: String, apiKey: String, model: String, language: String?, prompt: String?, customVocabulary: [String]) async throws -> String {
        let batchModel = model == "voxtral-mini-transcribe-realtime-3-0"
            ? "voxtral-mini-transcribe-3-0"
            : model
        return try await MistralTranscriptionClient.transcribe(
            audioData: audioData,
            fileName: fileName,
            apiKey: apiKey,
            model: batchModel
        )
    }

    func makeStreamingProvider(customVocabulary _: [String]) -> (any StreamingTranscriptionProvider)? {
        MistralStreamingProvider()
    }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        return await MistralTranscriptionClient.verifyAPIKey(key)
    }

    private enum VoxtralLanguages {
        static let fileCodes = [
            "ar", "bn", "bg", "ca", "zh", "hr", "cs", "da", "nl", "en",
            "et", "fi", "fr", "de", "el", "gu", "hi", "hu", "is", "id",
            "ga", "it", "ja", "kn", "ko", "lv", "lt", "mk", "ms", "ml",
            "mt", "mr", "no", "fa", "pl", "pt", "ro", "ru", "sk", "sl",
            "es", "sv", "tl", "te", "th", "tr", "uk", "vi",
        ]

        static let realtimeCodes = [
            "ar", "bn", "bg", "ca", "zh", "cs", "nl", "en", "et", "fi",
            "fr", "de", "el", "gu", "hi", "id", "it", "ja", "kn", "ko",
            "lv", "mk", "ms", "ml", "mr", "no", "fa", "pl", "pt", "ro",
            "ru", "sk", "es", "tl", "te", "tr",
        ]

        static let file = LanguageDictionary.forCodes(fileCodes, includesAutoDetect: true)
        static let realtime = LanguageDictionary.forCodes(realtimeCodes, includesAutoDetect: true)
    }
}
