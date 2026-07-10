import Foundation
import SwiftData
import os

/// Handles the full post-recording pipeline:
/// transcribe → filter → format → word-replace → AI enhance → deliver → save
@MainActor
class TranscriptionPipeline {
    struct AssistantHooks: Sendable {
        let isFollowUp: Bool
        let sendFollowUp: @MainActor @Sendable (String, Transcription) async -> Void
        let startResponse: @MainActor @Sendable (String, EnhancementRuntimeConfiguration) async -> Void
        let showResponse: @MainActor @Sendable (String, String?) async -> Void
        let failResponse: @MainActor @Sendable (String) async -> Void

        static let inactive = AssistantHooks(
            isFollowUp: false,
            sendFollowUp: { _, _ in },
            startResponse: { _, _ in },
            showResponse: { _, _ in },
            failResponse: { _ in }
        )
    }

    private let modelContext: ModelContext
    private let serviceRegistry: TranscriptionServiceRegistry
    private let enhancementService: AIEnhancementService?
    private let delivery = TranscriptionDelivery()
    private let logger = Logger(subsystem: "com.metrovoc.voiceink", category: "TranscriptionPipeline")

    init(
        modelContext: ModelContext,
        serviceRegistry: TranscriptionServiceRegistry,
        enhancementService: AIEnhancementService?
    ) {
        self.modelContext = modelContext
        self.serviceRegistry = serviceRegistry
        self.enhancementService = enhancementService
    }

    /// Run the full pipeline for a given transcription record.
    /// - Parameters:
    ///   - transcription: The pending Transcription SwiftData object to populate and save.
    ///   - audioURL: The recorded audio file.
    ///   - transcriptionConfiguration: Mode-resolved transcription engine settings for this phase.
    ///   - session: An active streaming session if one was prepared, otherwise nil.
    ///   - onStateChange: Called when the pipeline moves to a new recording state (e.g. `.enhancing`).
    ///   - shouldCancel: Returns true if the user requested cancellation.
    ///   - onCancel: Called when cancellation is detected to cancel active session state.
    ///   - onDismiss: Called when delivery should close the recorder panel.
    func run(
        transcription: Transcription,
        audioURL: URL,
        transcriptionConfiguration: TranscriptionRuntimeConfiguration,
        formattingConfiguration resolveFormattingConfiguration: @escaping () -> TranscriptionFormattingConfiguration,
        session: TranscriptionSession?,
        enhancementConfiguration: @escaping () -> EnhancementRuntimeConfiguration?,
        recordingContextSnapshot: @escaping () async -> RecordingContextSnapshot? = { nil },
        outputConfiguration: @escaping () -> OutputRuntimeConfiguration,
        onStateChange: @escaping (RecordingState) -> Void,
        shouldCancel: () -> Bool,
        onCancel: @escaping () async -> Void,
        onDismiss: @escaping () async -> Void,
        assistant: AssistantHooks = .inactive,
        performanceTrace: RealtimePerformanceTrace? = nil,
        wasPersistedPending: Bool = false
    ) async {
        let model = transcriptionConfiguration.model
        var finalText: String?
        var didInsertSessionMetric = false
        var responseError: String?
        var outputForDelivery: OutputRuntimeConfiguration?
        var responseConfig: EnhancementRuntimeConfiguration?

        func finishCanceledTranscription() async {
            await onCancel()

            let canceledDuration: TimeInterval?
            if transcription.duration > 0 {
                canceledDuration = nil
            } else {
                let duration = await AudioFileMetadata.duration(for: audioURL)
                canceledDuration = duration > 0 ? duration : nil
            }

            transcription.markAsCanceledTranscription(
                duration: canceledDuration,
                modelName: transcription.transcriptionModelName ?? model.displayName
            )

            do {
                if !wasPersistedPending {
                    modelContext.insert(transcription)
                }
                try modelContext.save()
                if !wasPersistedPending {
                    NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
                }
                NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
            } catch {
                logger.error("Failed to save canceled transcription: \(error, privacy: .public)")
            }
        }

        if shouldCancel() {
            await finishCanceledTranscription()
            return
        }

        do {
            let transcriptionStart = Date()
            var text: String
            if let session {
                text = try await session.transcribe(audioURL: audioURL)
            } else {
                text = try await serviceRegistry.transcribe(
                    audioURL: audioURL,
                    model: model,
                    context: transcriptionConfiguration.requestContext
                )
            }
            performanceTrace?.mark(.finalReceived)
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)

            if shouldCancel() { await finishCanceledTranscription(); return }

            let formattingConfiguration = resolveFormattingConfiguration()
            let processingInput = TranscriptionTextProcessingInput(
                text: text,
                fillerWords: FillerWordManager.shared.fillerWords,
                formatsParagraphs: formattingConfiguration.isTextFormattingEnabled,
                wordReplacements: WordReplacementService.shared.enabledRules(using: modelContext),
                textRules: TextTransformService.shared.enabledRules(using: modelContext),
                punctuationMode: formattingConfiguration.punctuationCleanupMode,
                lowercasesText: formattingConfiguration.lowercaseTranscription
            )
            let processingResult = await Task.detached(priority: .userInitiated) {
                TranscriptionTextProcessor.process(processingInput)
            }.value
            text = processingResult.transformedText
            let cleanedText = processingResult.cleanedText

            let actualDuration = await AudioFileMetadata.duration(for: audioURL)
            let modeMetadata = transcriptionConfiguration.metadata

            transcription.text = cleanedText
            transcription.duration = actualDuration
            transcription.transcriptionModelName = model.displayName
            transcription.transcriptionDuration = transcriptionDuration
            transcription.modeName = modeMetadata.name
            transcription.modeEmoji = modeMetadata.emoji
            finalText = cleanedText

            if !assistant.isFollowUp {
                var resolvedEnhancementConfiguration = enhancementConfiguration()
                var promptDetection: PromptDetectionService.Detection?

                if let enhancementService,
                   let currentConfiguration = resolvedEnhancementConfiguration,
                   currentConfiguration.provider != nil {
                    let prompts = enhancementService.allPrompts
                    let textForDetection = text
                    let detection = await Task.detached(priority: .utility) { @Sendable in
                        PromptDetectionService().detectPrompt(
                            in: textForDetection,
                            prompts: prompts
                        )
                    }.value
                    if let detection {
                        resolvedEnhancementConfiguration = currentConfiguration.replacingPrompt(detection.prompt)
                        promptDetection = detection
                    }
                }

                let resolvedOutputConfiguration = outputConfiguration()
                let shouldRespondInRecorder = resolvedOutputConfiguration.outputMode == .respond &&
                    resolvedEnhancementConfiguration?.isEnabled == true &&
                    resolvedEnhancementConfiguration.map { configuration in
                        enhancementService?.isConfigured(for: configuration) == true
                    } == true
                outputForDelivery = resolvedOutputConfiguration
                responseConfig = shouldRespondInRecorder ? resolvedEnhancementConfiguration : nil

                let isSkipShortEnhancementEnabled = UserDefaults.standard.bool(forKey: "SkipShortEnhancement")
                let savedThreshold = UserDefaults.standard.integer(forKey: "ShortEnhancementWordThreshold")
                let shortEnhancementWordThreshold = savedThreshold > 0 ? savedThreshold : 3
                let shouldSkipEnhancement = !shouldRespondInRecorder &&
                    isSkipShortEnhancementEnabled &&
                    processingResult.wordCount <= shortEnhancementWordThreshold &&
                    promptDetection == nil

                if let enhancementService,
                   let resolvedEnhancementConfiguration,
                   resolvedEnhancementConfiguration.isEnabled,
                   enhancementService.isConfigured(for: resolvedEnhancementConfiguration),
                   !shouldSkipEnhancement {
                    if shouldCancel() { await finishCanceledTranscription(); return }

                    onStateChange(.enhancing)
                    let textForAI = promptDetection?.processedText ?? text
                    if shouldRespondInRecorder {
                        await assistant.startResponse(textForAI, resolvedEnhancementConfiguration)
                    }

                    do {
                        let contextSnapshot = await recordingContextSnapshot()
                        let enhancement = try await enhancementService.enhanceDetailed(
                            textForAI,
                            configuration: resolvedEnhancementConfiguration,
                            contextSnapshot: contextSnapshot
                        )
                        transcription.enhancedText = enhancement.text
                        transcription.aiEnhancementModelName = resolvedEnhancementConfiguration.modelName ?? resolvedEnhancementConfiguration.provider?.defaultModel
                        transcription.promptName = enhancement.promptName
                        transcription.enhancementDuration = enhancement.duration
                        transcription.aiRequestSystemMessage = enhancement.systemMessage
                        transcription.aiRequestUserMessage = enhancement.userMessage
                        finalText = enhancement.text
                    } catch {
                        let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        transcription.enhancedText = String(format: String(localized: "Enhancement failed: %@"), errorDescription)
                        responseError = errorDescription
                        let shortReason = String(errorDescription.prefix(80))
                        await MainActor.run {
                            NotificationManager.shared.showNotification(
                                title: String(format: String(localized: "Enhancement failed: %@"), shortReason),
                                type: .warning
                            )
                        }
                        if shouldCancel() { await finishCanceledTranscription(); return }
                    }
                }
            }

            transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue
        } catch {
            let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

            if let nativeAppleError = error as? NativeAppleTranscriptionService.ServiceError,
               nativeAppleError.shouldShowNotification {
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: errorDescription,
                        type: .error,
                        duration: 5.0
                    )
                }
            }

            transcription.text = String(format: String(localized: "Transcription Failed: %@"), errorDescription)
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
        }

        let metricWordCount: Int?
        if transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue {
            let metricText: String
            if let enhancedText = transcription.enhancedText,
               transcription.enhancementDuration != nil,
               !enhancedText.isEmpty {
                metricText = enhancedText
            } else {
                metricText = transcription.text
            }
            metricWordCount = await Task.detached(priority: .utility) {
                WordCounter.count(in: metricText)
            }.value
        } else {
            metricWordCount = nil
        }

        func saveTranscriptionAndPostCompletion() {
            // Persistence is deliberately ordered after provider finalization and
            // delivery. SwiftData work must never delay realtime commit or the
            // user's paste command.
            if !wasPersistedPending {
                modelContext.insert(transcription)
            }

            if transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue {
                do {
                    didInsertSessionMetric = try SessionMetricRecorder.recordRecorderSession(
                        transcription: transcription,
                        model: model,
                        in: modelContext,
                        wordCount: metricWordCount
                    )
                } catch {
                    logger.error("Failed to record session metric: \(error, privacy: .public)")
                }
            }

            do {
                try modelContext.save()
                if !wasPersistedPending {
                    NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
                }
                if didInsertSessionMetric {
                    NotificationCenter.default.post(name: .sessionMetricsDidChange, object: nil)
                }
                NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
            } catch {
                logger.error("Failed to save transcription: \(error, privacy: .public)")
            }
        }

        if shouldCancel() {
            await finishCanceledTranscription()
            return
        }

        await delivery.deliver(
            TranscriptionDelivery.Request(
                transcription: transcription,
                text: finalText,
                output: outputForDelivery ?? outputConfiguration(),
                responseConfig: responseConfig,
                responseError: responseError,
                isAssistantFollowUp: assistant.isFollowUp
            ),
            actions: TranscriptionDelivery.Actions(
                setState: onStateChange,
                dismiss: onDismiss,
                sendFollowUp: assistant.sendFollowUp,
                showResponse: assistant.showResponse,
                failResponse: assistant.failResponse
            )
        )
        performanceTrace?.mark(.delivered)

        saveTranscriptionAndPostCompletion()
    }
}
