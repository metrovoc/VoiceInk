import Foundation
import SwiftUI
import AVFoundation
import SwiftData
import AppKit
import os

private final class StartupAudioChunkRelay: @unchecked Sendable {
    struct DrainStats {
        let bufferedChunks: Int
        let bufferedBytes: Int
        let droppedChunks: Int
        let droppedBytes: Int
    }

    private let lock = NSLock()
    private let maxBufferedChunks: Int
    private var bufferedChunks: [Data] = []
    private var callback: ((Data) -> Void)?
    private var isDraining = false
    private var droppedChunks = 0
    private var droppedBytes = 0

    init(maxBufferedChunks: Int = 600) {
        self.maxBufferedChunks = maxBufferedChunks
    }

    func send(_ data: Data) {
        lock.lock()
        if let callback, !isDraining {
            lock.unlock()
            callback(data)
            return
        }

        if bufferedChunks.count >= maxBufferedChunks {
            let dropped = bufferedChunks.removeFirst()
            droppedChunks += 1
            droppedBytes += dropped.count
        }
        bufferedChunks.append(data)
        lock.unlock()
    }

    func attach(_ callback: @escaping (Data) -> Void) -> DrainStats {
        lock.lock()
        let chunksToDrain = bufferedChunks
        let stats = DrainStats(
            bufferedChunks: chunksToDrain.count,
            bufferedBytes: chunksToDrain.reduce(0) { $0 + $1.count },
            droppedChunks: droppedChunks,
            droppedBytes: droppedBytes
        )
        bufferedChunks.removeAll(keepingCapacity: false)
        droppedChunks = 0
        droppedBytes = 0
        self.callback = callback
        isDraining = true
        lock.unlock()

        for chunk in chunksToDrain {
            callback(chunk)
        }

        while true {
            lock.lock()
            let pendingChunks = bufferedChunks
            bufferedChunks.removeAll(keepingCapacity: false)
            if pendingChunks.isEmpty {
                isDraining = false
                lock.unlock()
                break
            }
            lock.unlock()

            for chunk in pendingChunks {
                callback(chunk)
            }
        }

        return stats
    }

    func discard() -> DrainStats {
        lock.lock()
        let stats = DrainStats(
            bufferedChunks: bufferedChunks.count,
            bufferedBytes: bufferedChunks.reduce(0) { $0 + $1.count },
            droppedChunks: droppedChunks,
            droppedBytes: droppedBytes
        )
        bufferedChunks.removeAll(keepingCapacity: false)
        droppedChunks = 0
        droppedBytes = 0
        callback = nil
        isDraining = false
        lock.unlock()
        return stats
    }
}

@MainActor
class VoiceInkEngine: NSObject, ObservableObject {
    private enum RecordingUseCase {
        case newSession
        case assistantFollowUp

        var isAssistantFollowUp: Bool {
            self == .assistantFollowUp
        }
    }

    @Published var recordingState: RecordingState = .idle
    @Published var shouldCancelRecording = false
    @Published var partialTranscript: String = ""
    var currentSession: TranscriptionSession?
    private var currentSessionTranscriptionConfiguration: TranscriptionRuntimeConfiguration?
    private var activeRecordingStartID: UUID?
    private var activePipelineTranscriptionID: UUID?
    private var canceledPipelineTranscriptionIDs = Set<UUID>()
    private var activeRecordingUseCase: RecordingUseCase = .newSession
    private var activePipelineUseCase: RecordingUseCase = .newSession
    private var activeRecordingContextStore: RecordingContextSnapshotStore?
    private var activeRecordingContextTasks: [Task<Void, Never>] = []
    private var isStartupAudioCaptureActive = false
    private var shouldStopAfterStartup = false

    let recorder = Recorder()
    var recordedFile: URL? = nil
    let recordingsDirectory: URL

    // Injected managers
    let whisperModelManager: WhisperModelManager
    let transcriptionModelManager: TranscriptionModelManager
    weak var recorderUIManager: RecorderPanelPresenting?

    let modelContext: ModelContext
    internal let serviceRegistry: TranscriptionServiceRegistry
    let enhancementService: AIEnhancementService?
    let assistantSession = AssistantSession()
    let assistantChat: AssistantChatService?
    private let pipeline: TranscriptionPipeline

    let logger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "VoiceInkEngine")

    init(
        modelContext: ModelContext,
        whisperModelManager: WhisperModelManager,
        transcriptionModelManager: TranscriptionModelManager,
        enhancementService: AIEnhancementService? = nil
    ) {
        self.modelContext = modelContext
        self.whisperModelManager = whisperModelManager
        self.transcriptionModelManager = transcriptionModelManager
        self.enhancementService = enhancementService
        if let aiService = enhancementService?.getAIService() {
            self.assistantChat = AssistantChatService(
                modelContext: modelContext,
                aiService: aiService
            )
        } else {
            self.assistantChat = nil
        }

        self.recordingsDirectory = AppPaths.recordingsDirectory

        self.serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: whisperModelManager,
            modelsDirectory: whisperModelManager.modelsDirectory,
            modelContext: modelContext
        )
        self.pipeline = TranscriptionPipeline(
            modelContext: modelContext,
            serviceRegistry: serviceRegistry,
            enhancementService: enhancementService
        )

        super.init()

        setupNotifications()
        createRecordingsDirectoryIfNeeded()
    }

    private func createRecordingsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.error("❌ Error creating recordings directory: \(error, privacy: .public)")
        }
    }

    func getEnhancementService() -> AIEnhancementService? {
        return enhancementService
    }

    // MARK: - Toggle Record

    func toggleRecord(modeId: UUID? = nil, isAssistantFollowUp: Bool = false) async {
        if recordingState == .starting {
            if isStartupAudioCaptureActive {
                shouldStopAfterStartup = true
                logger.notice("Deferring recording stop until startup completes")
            } else {
                logger.notice("Cancelling recording startup before audio capture starts")
                requestRecordingCancellation()
                await finishActiveRecorderCancellation()
                await finishRecorderSession()
            }
            return
        }

        if recordingState == .recording {
            await finishActiveRecording()
        } else {
            let canContinueAssistantSession = isAssistantFollowUp && assistantSession.canSendFollowUp
            let recordingUseCase: RecordingUseCase = canContinueAssistantSession ? .assistantFollowUp : .newSession

            activePipelineTranscriptionID = nil
            shouldCancelRecording = false
            isStartupAudioCaptureActive = false
            shouldStopAfterStartup = false
            partialTranscript = ""
            activeRecordingUseCase = recordingUseCase
            clearActiveRecordingContext()

            if !recordingUseCase.isAssistantFollowUp {
                assistantSession.reset()
            }

            requestRecordPermission { [self] granted in
                if granted {
                    Task { @MainActor [self] in
                        let startupStartedAt = ProcessInfo.processInfo.systemUptime
                        func startupElapsed() -> Double {
                            ProcessInfo.processInfo.systemUptime - startupStartedAt
                        }
                        let startID = UUID()
                        self.activeRecordingStartID = startID
                        self.logger.notice("Recording startup requested id=\(startID.uuidString, privacy: .public)")
                        let activeModeTask = ActiveWindowService.shared.beginApplyingConfiguration(modeId: modeId) { [weak self] in
                            guard let self else { return false }
                            return self.activeRecordingStartID == startID && !self.shouldCancelRecording
                        }

                        var didStartAudioCapture = false
                        do {
                            let fileName = "\(UUID().uuidString).wav"
                            let permanentURL = self.recordingsDirectory.appendingPathComponent(fileName)
                            self.recordedFile = permanentURL
                            let startupAudioRelay = StartupAudioChunkRelay()
                            self.recorder.onAudioChunk = { data in
                                startupAudioRelay.send(data)
                            }

                            self.recordingState = .starting
                            self.logger.notice("Recording startup state=starting elapsed=\(startupElapsed(), format: .fixed(precision: 3), privacy: .public)s")

                            guard self.activeRecordingStartID == startID,
                                  self.recorderUIManager?.isRecorderPanelVisible ?? false,
                                  !self.shouldCancelRecording else {
                                activeModeTask.cancel()
                                _ = startupAudioRelay.discard()
                                self.recorder.onAudioChunk = nil
                                if self.activeRecordingStartID == startID {
                                    self.recordedFile = nil
                                    self.recordingState = .idle
                                    self.activeRecordingStartID = nil
                                    self.isStartupAudioCaptureActive = false
                                    self.shouldStopAfterStartup = false
                                    self.clearActiveRecordingContext()
                                }
                                return
                            }

                            self.recorder.scheduleSystemMute()
                            try await self.recorder.startRecording(toOutputFile: permanentURL)
                            didStartAudioCapture = true
                            guard self.activeRecordingStartID == startID,
                                  self.recorderUIManager?.isRecorderPanelVisible ?? false,
                                  !self.shouldCancelRecording else {
                                _ = startupAudioRelay.discard()
                                self.recorder.onAudioChunk = nil
                                if self.shouldCancelRecording {
                                    await self.finishActiveRecorderCancellation()
                                } else if self.activeRecordingStartID == startID {
                                    await self.recorder.stopRecording()
                                    try? FileManager.default.removeItem(at: permanentURL)
                                    self.recordedFile = nil
                                    self.recordingState = .idle
                                    self.activeRecordingStartID = nil
                                    self.isStartupAudioCaptureActive = false
                                    self.shouldStopAfterStartup = false
                                    self.clearActiveRecordingContext()
                                    await self.cleanupResources()
                                }
                                return
                            }
                            self.isStartupAudioCaptureActive = true
                            self.logger.notice("Recording startup audio capture started elapsed=\(startupElapsed(), format: .fixed(precision: 3), privacy: .public)s")
                            self.startRecordingContextCapture()
                            await activeModeTask.value
                            self.logger.notice("Recording startup mode configuration settled elapsed=\(startupElapsed(), format: .fixed(precision: 3), privacy: .public)s")

                            guard self.activeRecordingStartID == startID,
                                  self.recorderUIManager?.isRecorderPanelVisible ?? false,
                                  !self.shouldCancelRecording else {
                                _ = startupAudioRelay.discard()
                                self.recorder.onAudioChunk = nil
                                if self.shouldCancelRecording {
                                    await self.finishActiveRecorderCancellation()
                                } else if self.activeRecordingStartID == startID {
                                    await self.recorder.stopRecording()
                                    try? FileManager.default.removeItem(at: permanentURL)
                                    self.recordedFile = nil
                                    self.recordingState = .idle
                                    self.activeRecordingStartID = nil
                                    self.isStartupAudioCaptureActive = false
                                    self.shouldStopAfterStartup = false
                                    self.clearActiveRecordingContext()
                                    await self.cleanupResources()
                                }
                                return
                            }

                            guard let transcriptionConfiguration = ModeRuntimeResolver.transcriptionConfiguration(
                                transcriptionModelManager: self.transcriptionModelManager
                            ) else {
                                NotificationManager.shared.showNotification(title: String(localized: "No AI Model Selected"), type: .error)
                                await self.recorder.stopRecording()
                                _ = startupAudioRelay.discard()
                                self.recorder.onAudioChunk = nil
                                try? FileManager.default.removeItem(at: permanentURL)
                                self.recordedFile = nil
                                self.recordingState = .idle
                                self.activeRecordingStartID = nil
                                self.isStartupAudioCaptureActive = false
                                self.shouldStopAfterStartup = false
                                self.clearActiveRecordingContext()
                                await self.cleanupResources()
                                await self.recorderUIManager?.dismissRecorderPanel()
                                return
                            }
                            self.currentSessionTranscriptionConfiguration = transcriptionConfiguration
                            self.logger.notice("Recording startup configuration snapshot ready model=\(transcriptionConfiguration.model.displayName, privacy: .public) realtime=\(transcriptionConfiguration.isRealtimeEnabled, privacy: .public) elapsed=\(startupElapsed(), format: .fixed(precision: 3), privacy: .public)s")

                            let audioChunkCallback: ((Data) -> Void)?
                            if self.serviceRegistry.shouldUseRealtimeTranscription(for: transcriptionConfiguration) {
                                let session = self.serviceRegistry.createSession(
                                    for: transcriptionConfiguration,
                                    onPartialTranscript: { [weak self] partial in
                                        Task { @MainActor in
                                            guard let self,
                                                  self.activeRecordingStartID == startID,
                                                  self.recordingState == .recording else {
                                                return
                                            }
                                            self.partialTranscript = partial
                                        }
                                    }
                                )
                                self.currentSession = session
                                audioChunkCallback = try await session.prepare(configuration: transcriptionConfiguration)
                                self.logger.notice("Recording startup realtime callback ready elapsed=\(startupElapsed(), format: .fixed(precision: 3), privacy: .public)s")
                                if let audioChunkCallback {
                                    let drainStats = startupAudioRelay.attach(audioChunkCallback)
                                    self.logger.notice("Recording startup drained pre-session audio chunks=\(drainStats.bufferedChunks, privacy: .public) bytes=\(drainStats.bufferedBytes, privacy: .public) droppedChunks=\(drainStats.droppedChunks, privacy: .public) droppedBytes=\(drainStats.droppedBytes, privacy: .public)")
                                    if drainStats.droppedChunks > 0 {
                                        self.logger.error("Recording startup relay dropped pre-session audio; disabling realtime for this recording droppedChunks=\(drainStats.droppedChunks, privacy: .public) droppedBytes=\(drainStats.droppedBytes, privacy: .public)")
                                        self.cancelCurrentSession(preservingConfiguration: true)
                                        self.currentSession = nil
                                        self.recorder.onAudioChunk = nil
                                    }
                                }
                            } else {
                                self.currentSession = nil
                                audioChunkCallback = nil
                                let discardStats = startupAudioRelay.discard()
                                self.recorder.onAudioChunk = nil
                                self.logger.notice("Recording startup discarded pre-session audio for file transcription chunks=\(discardStats.bufferedChunks, privacy: .public) bytes=\(discardStats.bufferedBytes, privacy: .public)")
                            }

                            guard self.activeRecordingStartID == startID,
                                  self.recorderUIManager?.isRecorderPanelVisible ?? false,
                                  !self.shouldCancelRecording else {
                                _ = startupAudioRelay.discard()
                                self.cancelCurrentSession()
                                if self.shouldCancelRecording {
                                    await self.finishActiveRecorderCancellation()
                                } else {
                                    await self.recorder.stopRecording()
                                    self.recorder.onAudioChunk = nil
                                    try? FileManager.default.removeItem(at: permanentURL)
                                    self.recordedFile = nil
                                    self.recordingState = .idle
                                    self.activeRecordingStartID = nil
                                    self.isStartupAudioCaptureActive = false
                                    self.shouldStopAfterStartup = false
                                    self.clearActiveRecordingContext()
                                    await self.cleanupResources()
                                }
                                return
                            }

                            self.isStartupAudioCaptureActive = false
                            if self.shouldStopAfterStartup {
                                self.shouldStopAfterStartup = false
                                self.logger.notice("Recording startup completed with deferred stop elapsed=\(startupElapsed(), format: .fixed(precision: 3), privacy: .public)s")
                                await self.finishActiveRecording()
                                return
                            }

                            self.recordingState = .recording
                            self.logger.notice("Recording startup state=recording elapsed=\(startupElapsed(), format: .fixed(precision: 3), privacy: .public)s")

                            Task { @MainActor [weak self] in
                                guard let self else { return }

                                let currentModel = transcriptionConfiguration.model

                                if currentModel.provider == .whisper {
                                    if let localWhisperModel = self.whisperModelManager.availableModels.first(where: { $0.name == currentModel.name }),
                                       self.whisperModelManager.whisperContext == nil {
                                        do {
                                            try await self.whisperModelManager.loadModel(localWhisperModel)
                                        } catch {
                                            self.logger.error("❌ Model loading failed: \(error, privacy: .public)")
                                        }
                                    }
                                } else if let fluidAudioModel = currentModel as? FluidAudioModel {
                                    try? await self.serviceRegistry.fluidAudioTranscriptionService.loadModel(for: fluidAudioModel)
                                }

                            }

                        } catch {
                            activeModeTask.cancel()
                            let isStaleStart = self.activeRecordingStartID != startID
                            let wasCancelled = error is CancellationError
                                || self.shouldCancelRecording
                                || isStaleStart
                            if isStaleStart && !self.shouldCancelRecording && !didStartAudioCapture {
                                return
                            }
                            await self.recorder.stopRecording()
                            self.recorder.onAudioChunk = nil
                            self.cancelCurrentSession()
                            if let recordedFile = self.recordedFile {
                                try? FileManager.default.removeItem(at: recordedFile)
                            }
                            if self.activeRecordingStartID == startID || wasCancelled {
                                self.recordingState = .idle
                                self.recordedFile = nil
                                self.activeRecordingStartID = nil
                                self.isStartupAudioCaptureActive = false
                                self.shouldStopAfterStartup = false
                                self.clearActiveRecordingContext()
                                await self.cleanupResources()
                            }
                            if !wasCancelled {
                                self.logger.error("Recording failed to start: \(error, privacy: .public)")
                                NotificationManager.shared.showNotification(title: String(localized: "Recording failed to start"), type: .error)
                                await self.recorderUIManager?.dismissRecorderPanel()
                            }
                        }
                    }
                } else {
                    logger.error("Recording permission denied")
                }
            }
        }
    }

    private func requestRecordPermission(response: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            response(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted {
                        NotificationCenter.default.post(name: .microphonePermissionDidChange, object: nil)
                    }
                    response(granted)
                }
            }
        case .denied, .restricted:
            response(false)
        @unknown default:
            response(false)
        }
    }

    // MARK: - Recording Context

    private func startRecordingContextCapture() {
        clearActiveRecordingContext()

        let store = RecordingContextSnapshotStore()
        activeRecordingContextStore = store
        activeRecordingContextTasks = RecordingContextCaptureService.startCapture(into: store)
    }

    private func clearActiveRecordingContext() {
        activeRecordingContextTasks.forEach { $0.cancel() }
        activeRecordingContextTasks.removeAll()
        activeRecordingContextStore = nil
    }

    // MARK: - Pipeline Dispatch

    private func runPipeline(
        on transcription: Transcription,
        audioURL: URL,
        contextStore: RecordingContextSnapshotStore?
    ) async {
        guard let transcriptionConfiguration = currentSessionTranscriptionConfiguration ??
            ModeRuntimeResolver.transcriptionConfiguration(transcriptionModelManager: transcriptionModelManager) else {
            transcription.text = String(localized: "Transcription Failed: No model selected")
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
            try? modelContext.save()
            recordingState = .idle
            activePipelineUseCase = .newSession
            return
        }

        let session = currentSession
        let transcriptionID = transcription.id
        activePipelineTranscriptionID = transcriptionID

        await pipeline.run(
            transcription: transcription,
            audioURL: audioURL,
            transcriptionConfiguration: transcriptionConfiguration,
            formattingConfiguration: {
                ModeRuntimeResolver.transcriptionFormattingConfiguration(
                    mode: transcriptionConfiguration.mode
                )
            },
            session: session,
            enhancementConfiguration: { [weak self] in
                guard let self,
                      let enhancementService = self.enhancementService,
                      let aiService = enhancementService.getAIService() else {
                    return nil
                }
                return ModeRuntimeResolver.currentEnhancementConfiguration(
                    mode: transcriptionConfiguration.mode,
                    enhancementService: enhancementService,
                    aiService: aiService
                )
            },
            recordingContextSnapshot: {
                await MainActor.run {
                    contextStore?.snapshot
                }
            },
            outputConfiguration: {
                ModeRuntimeResolver.outputConfiguration(mode: transcriptionConfiguration.mode)
            },
            onStateChange: { [weak self] state in
                guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                self.recordingState = state
            },
            shouldCancel: { [weak self] in
                guard let self else { return false }
                return self.canceledPipelineTranscriptionIDs.contains(transcriptionID)
                    || (self.activePipelineTranscriptionID == transcriptionID && self.shouldCancelRecording)
            },
            onCancel: { [weak self, session] in
                guard let self else { return }
                self.cancelPipelineSession(transcriptionID: transcriptionID, session: session)
            },
            onDismiss: { [weak self] in
                guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                await self.recorderUIManager?.dismissRecorderPanel()
            },
            assistant: TranscriptionPipeline.AssistantHooks(
                isFollowUp: activePipelineUseCase.isAssistantFollowUp,
                sendFollowUp: { [weak self] text, transcription in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    await self.sendAssistantFollowUp(text, transcription: transcription)
                },
                startResponse: { [weak self] transcript, configuration in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    self.assistantSession.beginInitialResponse(
                        transcript: transcript,
                        provider: configuration.provider,
                        modelName: configuration.modelName ?? configuration.provider?.defaultModel,
                        modeName: configuration.mode?.name,
                        modeEmoji: configuration.mode?.icon.value,
                        promptName: configuration.prompt?.title
                    )
                },
                showResponse: { [weak self] response, systemPrompt in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    await self.completeAssistantResponse(response, systemPrompt: systemPrompt)
                },
                failResponse: { [weak self] message in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    self.assistantSession.fail(message)
                }
            )
        )

        let didFinishActivePipeline = activePipelineTranscriptionID == transcriptionID
        if didFinishActivePipeline {
            await finishRecorderSession()
            await cleanupResources()
            activePipelineTranscriptionID = nil
            currentSession = nil
            currentSessionTranscriptionConfiguration = nil
            recordedFile = nil
            shouldCancelRecording = false
            activePipelineUseCase = .newSession
            clearActiveRecordingContext()
        }
        canceledPipelineTranscriptionIDs.remove(transcriptionID)

        if didFinishActivePipeline &&
            (recordingState == .transcribing || recordingState == .enhancing || recordingState == .busy) {
            recordingState = .idle
        }
    }

    private func finishActiveRecording() async {
        activePipelineUseCase = activeRecordingUseCase
        activeRecordingUseCase = .newSession
        activeRecordingStartID = nil
        isStartupAudioCaptureActive = false
        shouldStopAfterStartup = false
        partialTranscript = ""
        recordingState = .transcribing
        await recorder.stopRecording()

        if let recordedFile {
            if !shouldCancelRecording {
                let transcription = makeRecordingTranscription(
                    for: recordedFile,
                    text: "",
                    duration: 0,
                    transcriptionStatus: .pending
                )
                modelContext.insert(transcription)
                try? modelContext.save()
                NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)

                await runPipeline(
                    on: transcription,
                    audioURL: recordedFile,
                    contextStore: activeRecordingContextStore
                )
            } else {
                await finishActiveRecorderCancellation()
            }
        } else {
            cancelCurrentSession()
            if !shouldCancelRecording {
                logger.error("❌ No recorded file found after stopping recording")
            }
            recordingState = .idle
            await cleanupResources()
        }
    }

    // MARK: - Cancellation

    func cancelRecording() async {
        let shouldFinishSessionImmediately: Bool
        switch recordingState {
        case .starting, .recording:
            requestRecordingCancellation()
            await finishActiveRecorderCancellation()
            shouldFinishSessionImmediately = true
        case .transcribing, .enhancing:
            requestRecordingCancellation()
            partialTranscript = ""
            recordingState = .idle
            shouldFinishSessionImmediately = false
        case .idle, .busy:
            partialTranscript = ""
            shouldCancelRecording = false
            recordingState = .idle
            shouldFinishSessionImmediately = true
        }

        if shouldFinishSessionImmediately {
            await finishRecorderSession()
        }
    }

    func resetRecordingSession() async {
        cancelCurrentSession()
        activeRecordingStartID = nil
        activePipelineTranscriptionID = nil
        canceledPipelineTranscriptionIDs.removeAll()
        shouldCancelRecording = false
        isStartupAudioCaptureActive = false
        shouldStopAfterStartup = false
        partialTranscript = ""
        assistantSession.reset()
        activeRecordingUseCase = .newSession
        activePipelineUseCase = .newSession
        clearActiveRecordingContext()
        await recorder.stopRecording()
        recordedFile = nil
        recordingState = .idle
        await cleanupResources()
        await finishRecorderSession()
    }

    private func requestRecordingCancellation() {
        shouldCancelRecording = true

        if (recordingState == .transcribing || recordingState == .enhancing),
           let activePipelineTranscriptionID {
            canceledPipelineTranscriptionIDs.insert(activePipelineTranscriptionID)
        }

        cancelCurrentSession()
    }

    private func finishActiveRecorderCancellation() async {
        activeRecordingStartID = nil
        isStartupAudioCaptureActive = false
        shouldStopAfterStartup = false
        clearActiveRecordingContext()
        recorder.onAudioChunk = nil
        await recorder.stopRecording()
        await saveCanceledRecording()
        recordedFile = nil
        partialTranscript = ""
        recordingState = .idle
        await cleanupResources()
    }

    private func saveCanceledRecording() async {
        guard let recordedFile,
              FileManager.default.fileExists(atPath: recordedFile.path)
        else { return }

        let duration = await AudioFileMetadata.duration(for: recordedFile)
        let transcription = makeRecordingTranscription(
            for: recordedFile,
            text: Transcription.canceledTranscriptionText,
            duration: duration,
            transcriptionStatus: .canceled
        )

        modelContext.insert(transcription)

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
        } catch {
            logger.error("Failed to save canceled recording: \(error, privacy: .public)")
        }
    }

    private func makeRecordingTranscription(
        for audioURL: URL,
        text: String,
        duration: TimeInterval,
        transcriptionStatus: TranscriptionStatus
    ) -> Transcription {
        let transcriptionConfiguration = currentSessionTranscriptionConfiguration ??
            ModeRuntimeResolver.transcriptionConfiguration(transcriptionModelManager: transcriptionModelManager)
        let modeMetadata = transcriptionConfiguration?.metadata ?? currentModeMetadata()

        return Transcription(
            text: text,
            duration: duration,
            audioFileURL: audioURL.absoluteString,
            transcriptionModelName: transcriptionConfiguration?.model.displayName,
            modeName: modeMetadata.name,
            modeEmoji: modeMetadata.emoji,
            transcriptionStatus: transcriptionStatus
        )
    }

    private func currentModeMetadata() -> (name: String?, emoji: String?) {
        guard let mode = ModeManager.shared.currentEffectiveConfiguration,
              mode.isEnabled else {
            return (nil, nil)
        }

        return (mode.name, mode.icon.value)
    }

    // MARK: - Resource Cleanup

    private func cancelPipelineSession(transcriptionID: UUID, session: TranscriptionSession?) {
        session?.cancel()

        guard activePipelineTranscriptionID == transcriptionID else {
            logger.notice("Skipping stale pipeline cleanup")
            return
        }

        currentSession = nil
        currentSessionTranscriptionConfiguration = nil
    }

    private func cancelCurrentSession(preservingConfiguration: Bool = false) {
        currentSession?.cancel()
        currentSession = nil
        if !preservingConfiguration {
            currentSessionTranscriptionConfiguration = nil
        }
    }

    private func finishRecorderSession() async {
        enhancementService?.clearCapturedContexts()
    }

    func cleanupResources() async {
        logger.notice("cleanupResources: releasing model resources")
        activeRecordingStartID = nil
        activeRecordingUseCase = .newSession
        isStartupAudioCaptureActive = false
        shouldStopAfterStartup = false
        await whisperModelManager.cleanupResources()
        await serviceRegistry.cleanup()
        logger.notice("cleanupResources: completed")
    }

    // MARK: - Notification Handling

    func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePromptChange),
            name: .promptDidChange,
            object: nil
        )
    }

    @objc func handlePromptChange() {
        Task {
            let currentPrompt = UserDefaults.standard.string(forKey: "TranscriptionPrompt")
                ?? whisperModelManager.whisperPrompt.transcriptionPrompt
            if let context = whisperModelManager.whisperContext {
                await context.setPrompt(currentPrompt)
            }
        }
    }
}

enum AudioFileMetadata {
    static func duration(for url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : 0
    }
}
