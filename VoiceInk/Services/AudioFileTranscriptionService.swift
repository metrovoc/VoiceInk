import Foundation
import SwiftUI
import AVFoundation
import SwiftData
import os

struct AudioRetranscriptionResult {
    let transcription: Transcription
    let enhancementFailure: String?
}

@MainActor
class AudioTranscriptionService: ObservableObject {
    @Published var isTranscribing = false
    @Published var currentError: TranscriptionError?

    private let modelContext: ModelContext
    private let enhancementService: AIEnhancementService?
    private let logger = Logger(subsystem: "com.metrovoc.voiceink", category: "AudioTranscriptionService")
    private let serviceRegistry: TranscriptionServiceRegistry

    enum TranscriptionError: Error {
        case noAudioFile
        case transcriptionFailed
        case modelNotLoaded
        case invalidAudioFormat
    }

    init(modelContext: ModelContext, engine: VoiceInkEngine) {
        self.modelContext = modelContext
        self.enhancementService = engine.enhancementService
        self.serviceRegistry = TranscriptionServiceRegistry(modelProvider: engine.whisperModelManager, modelsDirectory: engine.whisperModelManager.modelsDirectory, modelContext: modelContext)
    }

    init(modelContext: ModelContext, serviceRegistry: TranscriptionServiceRegistry, enhancementService: AIEnhancementService?) {
        self.modelContext = modelContext
        self.enhancementService = enhancementService
        self.serviceRegistry = serviceRegistry
    }
    
    func retranscribeAudio(from url: URL, using model: any TranscriptionModel, mode: ModeConfig? = nil) async throws -> AudioRetranscriptionResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.noAudioFile
        }
        
        await MainActor.run {
            isTranscribing = true
        }
        
        do {
            let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration
            let language = TranscriptionLanguageSupport.validLanguageOrFallback(
                mode?.selectedLanguage,
                for: model,
                realtimeEnabled: mode?.isRealtimeTranscriptionEnabled
            )
            let requestContext = TranscriptionRequestContext(
                language: language,
                prompt: model.provider == .whisper ? WhisperPrompt.resolvedPrompt(for: language) : nil
            )
            let modeName = (mode?.isEnabled == true) ? mode?.name : nil
            let modeEmoji = (mode?.isEnabled == true) ? mode?.icon.value : nil

            let transcriptionStart = Date()
            var text = try await serviceRegistry.transcribe(audioURL: url, model: model, context: requestContext)
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)
            text = TranscriptionOutputFilter.filter(text)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let formattingConfiguration = ModeRuntimeResolver.transcriptionFormattingConfiguration(mode: mode)

            if formattingConfiguration.isTextFormattingEnabled {
                text = ParagraphFormatter.format(text)
            }

            text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            logger.notice("✅ Word replacements applied")
            let cleanedText = TranscriptionOutputFilter.applyCleanupPreferences(
                text,
                punctuationMode: formattingConfiguration.punctuationCleanupMode,
                shouldLowercase: formattingConfiguration.lowercaseTranscription
            )

            let audioAsset = AVURLAsset(url: url)
            let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))
            let recordingsDirectory = AppPaths.recordingsDirectory
            
            let fileName = "retranscribed_\(UUID().uuidString).wav"
            let permanentURL = recordingsDirectory.appendingPathComponent(fileName)
            
            do {
                try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: permanentURL)
            } catch {
                logger.error("❌ Failed to create permanent copy of audio: \(error, privacy: .public)")
                isTranscribing = false
                throw error
            }
            
            let permanentURLString = permanentURL.absoluteString

            let originalText = cleanedText
            let enhancementConfiguration = enhancementService
                .flatMap { service in
                    service.getAIService().map { aiService in
                        ModeRuntimeResolver.currentEnhancementConfiguration(
                            mode: mode,
                            enhancementService: service,
                            aiService: aiService
                        )
                    }
                }

            // Apply AI enhancement if enabled
            if let enhancementService = enhancementService,
               let enhancementConfiguration,
               enhancementConfiguration.isEnabled,
               enhancementService.isConfigured(for: enhancementConfiguration) {
                do {
                    let enhancement = try await enhancementService.enhanceDetailed(
                        text,
                        configuration: enhancementConfiguration
                    )
                    let newTranscription = Transcription(
                        text: originalText,
                        duration: duration,
                        enhancedText: enhancement.text,
                        audioFileURL: permanentURLString,
                        transcriptionModelName: model.displayName,
                        aiEnhancementModelName: enhancementConfiguration.modelName ?? enhancementConfiguration.provider?.defaultModel,
                        promptName: enhancement.promptName,
                        transcriptionDuration: transcriptionDuration,
                        enhancementDuration: enhancement.duration,
                        aiRequestSystemMessage: enhancement.systemMessage,
                        aiRequestUserMessage: enhancement.userMessage,
                        modeName: modeName,
                        modeEmoji: modeEmoji
                    )
                    modelContext.insert(newTranscription)
                    do {
                        try modelContext.save()
                        NotificationCenter.default.post(name: .transcriptionCreated, object: newTranscription)
                        NotificationCenter.default.post(name: .transcriptionCompleted, object: newTranscription)
                    } catch {
                        logger.error("❌ Failed to save transcription: \(error, privacy: .public)")
                    }
                    await MainActor.run {
                        isTranscribing = false
                    }

                    return AudioRetranscriptionResult(
                        transcription: newTranscription,
                        enhancementFailure: nil
                    )
                } catch {
                    let enhancementFailure = EnhancementFailureFormatter.description(for: error)
                    let newTranscription = Transcription(
                        text: originalText,
                        duration: duration,
                        audioFileURL: permanentURLString,
                        transcriptionModelName: model.displayName,
                        promptName: nil,
                        transcriptionDuration: transcriptionDuration,
                        modeName: modeName,
                        modeEmoji: modeEmoji
                    )
                    modelContext.insert(newTranscription)
                    do {
                        try modelContext.save()
                        NotificationCenter.default.post(name: .transcriptionCreated, object: newTranscription)
                        NotificationCenter.default.post(name: .transcriptionCompleted, object: newTranscription)
                    } catch {
                        logger.error("❌ Failed to save transcription: \(error, privacy: .public)")
                    }

                    await MainActor.run {
                        isTranscribing = false
                    }

                    return AudioRetranscriptionResult(
                        transcription: newTranscription,
                        enhancementFailure: enhancementFailure
                    )
                }
            } else {
                let newTranscription = Transcription(
                    text: originalText,
                    duration: duration,
                    audioFileURL: permanentURLString,
                    transcriptionModelName: model.displayName,
                    promptName: nil,
                    transcriptionDuration: transcriptionDuration,
                    modeName: modeName,
                    modeEmoji: modeEmoji
                )
                modelContext.insert(newTranscription)
                do {
                    try modelContext.save()
                    NotificationCenter.default.post(name: .transcriptionCompleted, object: newTranscription)
                } catch {
                    logger.error("❌ Failed to save transcription: \(error, privacy: .public)")
                }

                await MainActor.run {
                    isTranscribing = false
                }

                return AudioRetranscriptionResult(
                    transcription: newTranscription,
                    enhancementFailure: nil
                )
            }
        } catch {
            logger.error("❌ Transcription failed: \(error, privacy: .public)")
            currentError = .transcriptionFailed
            isTranscribing = false
            throw error
        }
    }
}
