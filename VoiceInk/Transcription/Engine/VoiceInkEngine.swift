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

enum RecordingControlPlaneStopAction: Equatable {
    case finishImmediately
    case stopRecorderAndWaitForControlPlane
}

enum RecordingControlPlaneStopPolicy {
    static func action(activeRecordingStartID: UUID?, isControlPlaneReady: Bool) -> RecordingControlPlaneStopAction {
        activeRecordingStartID != nil && !isControlPlaneReady
            ? .stopRecorderAndWaitForControlPlane
            : .finishImmediately
    }
}

enum RecordingStartupContinuationPolicy {
    static func shouldContinue(
        activeRecordingStartID: UUID?,
        startID: UUID,
        shouldCancelRecording: Bool
    ) -> Bool {
        activeRecordingStartID == startID && !shouldCancelRecording
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

    private struct PreparedRealtimeSession {
        let configuration: TranscriptionRuntimeConfiguration
        let session: TranscriptionSession
        let audioChunkCallback: (Data) -> Void
    }

    private struct EarlyRealtimePreconnect {
        let configuration: TranscriptionRuntimeConfiguration
        let task: Task<PreparedRealtimeSession?, Error>
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
    private var activeHardwareStart: RecordingHardwareStartHandle?
    private var activeRecordingContextStore: RecordingContextSnapshotStore?
    private var activeRecordingContextTasks: [Task<Void, Never>] = []
    private var isStartupAudioCaptureActive = false
    private var isRecordingControlPlaneReady = false
    private var shouldStopAfterStartup = false
    private var pendingPartialTranscript: String?
    private var partialTranscriptUpdateTask: Task<Void, Never>?
    private var lastPartialTranscriptUpdateTime: TimeInterval = 0
    private let partialTranscriptPublishInterval: TimeInterval = 0.1
    private let startupModeSettleBudgetNanoseconds: UInt64 = 120_000_000

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

    private func schedulePartialTranscriptUpdate(_ partial: String, for startID: UUID) {
        pendingPartialTranscript = partial

        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastPartialTranscriptUpdateTime
        if elapsed >= partialTranscriptPublishInterval {
            flushPendingPartialTranscript(for: startID)
            return
        }

        guard partialTranscriptUpdateTask == nil else { return }

        let delay = UInt64((partialTranscriptPublishInterval - elapsed) * 1_000_000_000)
        partialTranscriptUpdateTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard let self else { return }
            self.partialTranscriptUpdateTask = nil
            self.flushPendingPartialTranscript(for: startID)
        }
    }

    private func flushPendingPartialTranscript(for startID: UUID) {
        guard activeRecordingStartID == startID,
              recordingState == .starting || recordingState == .recording,
              let partial = pendingPartialTranscript else {
            return
        }

        pendingPartialTranscript = nil
        lastPartialTranscriptUpdateTime = ProcessInfo.processInfo.systemUptime
        if partialTranscript != partial {
            partialTranscript = partial
        }
    }

    private func clearPartialTranscript() {
        partialTranscriptUpdateTask?.cancel()
        partialTranscriptUpdateTask = nil
        pendingPartialTranscript = nil
        lastPartialTranscriptUpdateTime = 0
        if !partialTranscript.isEmpty {
            partialTranscript = ""
        }
    }

    private func makePartialTranscriptHandler(for startID: UUID) -> @MainActor (String) -> Void {
        { [weak self] partial in
            guard let self,
                  self.activeRecordingStartID == startID,
                  self.recordingState == .starting || self.recordingState == .recording else {
                return
            }
            self.schedulePartialTranscriptUpdate(partial, for: startID)
        }
    }

    private func prepareRealtimeSessionIfNeeded(
        configuration: TranscriptionRuntimeConfiguration,
        startID: UUID
    ) async throws -> PreparedRealtimeSession? {
        guard serviceRegistry.shouldUseRealtimeTranscription(for: configuration) else {
            return nil
        }

        let session = serviceRegistry.createSession(
            for: configuration,
            onPartialTranscript: makePartialTranscriptHandler(for: startID)
        )
        guard let callback = try await session.prepare(configuration: configuration) else {
            return nil
        }

        return PreparedRealtimeSession(
            configuration: configuration,
            session: session,
            audioChunkCallback: callback
        )
    }

    private func beginRealtimePreconnectIfNeeded(
        configuration: TranscriptionRuntimeConfiguration,
        startID: UUID,
        startupStartedAt: TimeInterval
    ) -> EarlyRealtimePreconnect? {
        guard serviceRegistry.shouldUseRealtimeTranscription(for: configuration) else {
            return nil
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }

            let preconnectStartedAt = ProcessInfo.processInfo.systemUptime
            try Task.checkCancellation()
            let preparedSession = try await self.prepareRealtimeSessionIfNeeded(
                configuration: configuration,
                startID: startID
            )
            if Task.isCancelled {
                preparedSession?.session.cancel()
                throw CancellationError()
            }
            if preparedSession != nil {
                let now = ProcessInfo.processInfo.systemUptime
                self.logger.notice("Recording startup realtime preconnect started model=\(configuration.model.displayName, privacy: .public) elapsed=\(now - startupStartedAt, format: .fixed(precision: 3), privacy: .public)s duration=\(now - preconnectStartedAt, format: .fixed(precision: 3), privacy: .public)s")
            }
            return preparedSession
        }

        return EarlyRealtimePreconnect(configuration: configuration, task: task)
    }

    private func discardEarlyRealtimePreconnect(
        _ preconnect: EarlyRealtimePreconnect?,
        reason: String
    ) {
        guard let preconnect else { return }

        preconnect.task.cancel()
        Task { @MainActor [weak self] in
            do {
                if let preparedSession = try await preconnect.task.value {
                    preparedSession.session.cancel()
                    self?.logger.notice("Recording startup discarded early realtime session reason=\(reason, privacy: .public)")
                }
            } catch {
                // Cancellation or startup failure means there is no reusable session to clean up.
            }
        }
    }

    private func beginInitialRealtimePreconnect(
        startID: UUID,
        startupStartedAt: TimeInterval
    ) -> EarlyRealtimePreconnect? {
        ModeRuntimeResolver.transcriptionConfiguration(
            transcriptionModelManager: transcriptionModelManager
        ).flatMap { initialConfiguration in
            beginRealtimePreconnectIfNeeded(
                configuration: initialConfiguration,
                startID: startID,
                startupStartedAt: startupStartedAt
            )
        }
    }

    private func realtimeConfigurationMatches(
        _ lhs: TranscriptionRuntimeConfiguration,
        _ rhs: TranscriptionRuntimeConfiguration
    ) -> Bool {
        lhs.isRealtimeEnabled == rhs.isRealtimeEnabled &&
            lhs.model.name == rhs.model.name &&
            lhs.model.provider == rhs.model.provider &&
            lhs.language == rhs.language &&
            lhs.requestContext.prompt == rhs.requestContext.prompt
    }

    private func waitForStartupModeConfiguration(
        _ task: Task<Void, Never>,
        budgetNanoseconds: UInt64
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: budgetNanoseconds)
                return false
            }

            let didSettle = await group.next() ?? false
            group.cancelAll()
            return didSettle
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
            switch RecordingControlPlaneStopPolicy.action(
                activeRecordingStartID: activeRecordingStartID,
                isControlPlaneReady: isRecordingControlPlaneReady
            ) {
            case .stopRecorderAndWaitForControlPlane:
                shouldStopAfterStartup = true
                recordingState = .transcribing
                logger.notice("Stopping recorder while recording control plane prepares")
                await recorder.stopRecording()
            case .finishImmediately:
                await finishActiveRecording()
            }
        } else {
            let canContinueAssistantSession = isAssistantFollowUp && assistantSession.canSendFollowUp
            let recordingUseCase: RecordingUseCase = canContinueAssistantSession ? .assistantFollowUp : .newSession

            activePipelineTranscriptionID = nil
            shouldCancelRecording = false
            isStartupAudioCaptureActive = false
            isRecordingControlPlaneReady = false
            shouldStopAfterStartup = false
            clearPartialTranscript()
            activeRecordingUseCase = recordingUseCase
            clearActiveRecordingContext()

            if !recordingUseCase.isAssistantFollowUp {
                assistantSession.reset()
            }

            requestRecordPermission { [self] granted in
                if granted {
                    let startupStartedAt = ProcessInfo.processInfo.systemUptime
                    func startupElapsed() -> Double {
                        ProcessInfo.processInfo.systemUptime - startupStartedAt
                    }
                    self.cancelActiveHardwareStart()
                    let startID = UUID()
                    self.activeRecordingStartID = startID
                    self.logger.notice("Recording startup requested id=\(startID.uuidString, privacy: .public)")

                    let fileName = "\(UUID().uuidString).wav"
                    let permanentURL = self.recordingsDirectory.appendingPathComponent(fileName)
                    self.recordedFile = permanentURL
                    let startupAudioRelay = StartupAudioChunkRelay()
                    self.recorder.onAudioChunk = { data in
                        startupAudioRelay.send(data)
                    }
                    self.recordingState = .starting
                    self.logger.notice("Recording startup state=starting elapsed=\(startupElapsed(), format: .fixed(precision: 3), privacy: .public)s")

                    guard RecordingStartupContinuationPolicy.shouldContinue(
                        activeRecordingStartID: self.activeRecordingStartID,
                        startID: startID,
                        shouldCancelRecording: self.shouldCancelRecording
                    ) else {
                        _ = startupAudioRelay.discard()
                        self.recorder.onAudioChunk = nil
                        if self.activeRecordingStartID == startID {
                            self.recordedFile = nil
                            self.recordingState = .idle
                            self.activeRecordingStartID = nil
                            self.isStartupAudioCaptureActive = false
                            self.isRecordingControlPlaneReady = false
                            self.shouldStopAfterStartup = false
                            self.clearActiveRecordingContext()
                        }
                        return
                    }

                    self.recorder.scheduleSystemMute()
                    let hardwareStartStartedAt = ProcessInfo.processInfo.systemUptime
                    let hardwareStart = self.recorder.beginStartRecording(toOutputFile: permanentURL)
                    self.activeHardwareStart = hardwareStart

                    let modeTask = ActiveWindowService.shared.beginApplyingConfiguration(modeId: modeId) { [weak self] in
                        guard let self else { return false }
                        return self.activeRecordingStartID == startID && !self.shouldCancelRecording
                    }

                    Task { @MainActor [self] in
                        let activeModeTask = modeTask
                        do {
                            var initialRealtimePreconnect: EarlyRealtimePreconnect?
                            var didHandleInitialRealtimePreconnect = false
                            var preparedRealtimeSession: PreparedRealtimeSession?
                            var didConsumePreparedRealtimeSession = false
                            defer {
                                if !didConsumePreparedRealtimeSession {
                                    preparedRealtimeSession?.session.cancel()
                                }
                                if !didHandleInitialRealtimePreconnect {
                                    self.discardEarlyRealtimePreconnect(
                                        initialRealtimePreconnect,
                                        reason: "startup abandoned"
                                    )
                                }
                            }

                            let hardwareStartResult = try await hardwareStart.value()
                            guard self.activeHardwareStart === hardwareStart else {
                                throw CancellationError()
                            }
                            self.activeHardwareStart = nil
                            self.recorder.finishStartRecording(hardwareStartResult, startTime: hardwareStartStartedAt)
                            guard RecordingStartupContinuationPolicy.shouldContinue(
                                activeRecordingStartID: self.activeRecordingStartID,
                                startID: startID,
                                shouldCancelRecording: self.shouldCancelRecording
                            ) else {
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
                                    self.isRecordingControlPlaneReady = false
                                    self.shouldStopAfterStartup = false
                                    self.clearActiveRecordingContext()
                                    await self.cleanupResources()
                                }
                                return
                            }
                            self.isStartupAudioCaptureActive = true
                            self.logger.notice("Recording startup audio capture started elapsed=\(startupElapsed(), format: .fixed(precision: 3), privacy: .public)s")
                            self.startRecordingContextCapture()
                            self.isStartupAudioCaptureActive = false
                            self.recordingState = .recording
                            self.logger.notice("Recording startup state=recording elapsed=\(startupElapsed(), format: .fixed(precision: 3), privacy: .public)s")
                            initialRealtimePreconnect = self.beginInitialRealtimePreconnect(
                                startID: startID,
                                startupStartedAt: startupStartedAt
                            )

                            guard RecordingStartupContinuationPolicy.shouldContinue(
                                activeRecordingStartID: self.activeRecordingStartID,
                                startID: startID,
                                shouldCancelRecording: self.shouldCancelRecording
                            ) else {
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
                                    self.isRecordingControlPlaneReady = false
                                    self.shouldStopAfterStartup = false
                                    self.clearActiveRecordingContext()
                                    await self.cleanupResources()
                                }
                                return
                            }

                            let modeSettled = await self.waitForStartupModeConfiguration(
                                activeModeTask,
                                budgetNanoseconds: self.startupModeSettleBudgetNanoseconds
                            )
                            if modeSettled {
                                self.logger.notice("Recording startup mode configuration settled elapsed=\(startupElapsed(), format: .fixed(precision: 3), privacy: .public)s")
                            } else {
                                self.logger.notice("Recording startup proceeding with current mode configuration while URL lookup continues elapsed=\(startupElapsed(), format: .fixed(precision: 3), privacy: .public)s")
                            }

                            guard RecordingStartupContinuationPolicy.shouldContinue(
                                activeRecordingStartID: self.activeRecordingStartID,
                                startID: startID,
                                shouldCancelRecording: self.shouldCancelRecording
                            ) else {
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
                                    self.isRecordingControlPlaneReady = false
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
                                self.isRecordingControlPlaneReady = false
                                self.shouldStopAfterStartup = false
                                self.clearActiveRecordingContext()
                                await self.cleanupResources()
                                await self.recorderUIManager?.dismissRecorderPanel()
                                return
                            }
                            self.currentSessionTranscriptionConfiguration = transcriptionConfiguration
                            self.logger.notice("Recording startup configuration snapshot ready model=\(transcriptionConfiguration.model.displayName, privacy: .public) realtime=\(transcriptionConfiguration.isRealtimeEnabled, privacy: .public) elapsed=\(startupElapsed(), format: .fixed(precision: 3), privacy: .public)s")

                            if let initialRealtimePreconnect {
                                if self.realtimeConfigurationMatches(initialRealtimePreconnect.configuration, transcriptionConfiguration) {
                                    didHandleInitialRealtimePreconnect = true
                                    do {
                                        preparedRealtimeSession = try await initialRealtimePreconnect.task.value
                                    } catch is CancellationError {
                                        throw CancellationError()
                                    } catch {
                                        self.logger.warning("Recording startup early realtime preconnect failed error=\(error, privacy: .public)")
                                    }
                                } else {
                                    didHandleInitialRealtimePreconnect = true
                                    self.discardEarlyRealtimePreconnect(
                                        initialRealtimePreconnect,
                                        reason: "final configuration changed"
                                    )
                                }
                            }

                            let audioChunkCallback: ((Data) -> Void)?
                            if self.serviceRegistry.shouldUseRealtimeTranscription(for: transcriptionConfiguration) {
                                if let preparedRealtimeSession,
                                   self.realtimeConfigurationMatches(preparedRealtimeSession.configuration, transcriptionConfiguration),
                                   preparedRealtimeSession.session.canReusePreparedSession() {
                                    self.currentSession = preparedRealtimeSession.session
                                    audioChunkCallback = preparedRealtimeSession.audioChunkCallback
                                    didConsumePreparedRealtimeSession = true
                                    self.logger.notice("Recording startup reused early realtime session elapsed=\(startupElapsed(), format: .fixed(precision: 3), privacy: .public)s")
                                } else {
                                    if let preparedRealtimeSession,
                                       !self.realtimeConfigurationMatches(preparedRealtimeSession.configuration, transcriptionConfiguration) {
                                        self.logger.notice("Recording startup discarded early realtime session because final configuration changed")
                                    } else if preparedRealtimeSession != nil {
                                        self.logger.notice("Recording startup discarded early realtime session because it was no longer reusable")
                                    }
                                    preparedRealtimeSession?.session.cancel()
                                    preparedRealtimeSession = nil

                                    let session = self.serviceRegistry.createSession(
                                        for: transcriptionConfiguration,
                                        onPartialTranscript: self.makePartialTranscriptHandler(for: startID)
                                    )
                                    self.currentSession = session
                                    audioChunkCallback = try await session.prepare(configuration: transcriptionConfiguration)
                                    self.logger.notice("Recording startup realtime callback ready elapsed=\(startupElapsed(), format: .fixed(precision: 3), privacy: .public)s")
                                }
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

                            guard RecordingStartupContinuationPolicy.shouldContinue(
                                activeRecordingStartID: self.activeRecordingStartID,
                                startID: startID,
                                shouldCancelRecording: self.shouldCancelRecording
                            ) else {
                                _ = startupAudioRelay.discard()
                                self.cancelCurrentSession()
                                if self.shouldCancelRecording {
                                    await self.finishActiveRecorderCancellation()
                                } else if self.activeRecordingStartID == startID {
                                    await self.recorder.stopRecording()
                                    self.recorder.onAudioChunk = nil
                                    try? FileManager.default.removeItem(at: permanentURL)
                                    self.recordedFile = nil
                                    self.recordingState = .idle
                                    self.activeRecordingStartID = nil
                                    self.isStartupAudioCaptureActive = false
                                    self.isRecordingControlPlaneReady = false
                                    self.shouldStopAfterStartup = false
                                    self.clearActiveRecordingContext()
                                    await self.cleanupResources()
                                }
                                return
                            }

                            self.isRecordingControlPlaneReady = true
                            if self.shouldStopAfterStartup {
                                self.shouldStopAfterStartup = false
                                self.logger.notice("Recording startup completed with deferred stop elapsed=\(startupElapsed(), format: .fixed(precision: 3), privacy: .public)s")
                                await self.finishActiveRecording()
                                return
                            }

                            self.logger.notice("Recording startup control plane ready elapsed=\(startupElapsed(), format: .fixed(precision: 3), privacy: .public)s")

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
                            if self.activeHardwareStart === hardwareStart {
                                self.activeHardwareStart = nil
                            }
                            if isStaleStart && !self.shouldCancelRecording {
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
                                self.isRecordingControlPlaneReady = false
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
        isRecordingControlPlaneReady = false
        shouldStopAfterStartup = false
        clearPartialTranscript()
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
            clearPartialTranscript()
            recordingState = .idle
            shouldFinishSessionImmediately = false
        case .idle, .busy:
            clearPartialTranscript()
            shouldCancelRecording = false
            recordingState = .idle
            shouldFinishSessionImmediately = true
        }

        if shouldFinishSessionImmediately {
            await finishRecorderSession()
        }
    }

    func resetRecordingSession() async {
        cancelActiveHardwareStart()
        cancelCurrentSession()
        activeRecordingStartID = nil
        activePipelineTranscriptionID = nil
        canceledPipelineTranscriptionIDs.removeAll()
        shouldCancelRecording = false
        isStartupAudioCaptureActive = false
        isRecordingControlPlaneReady = false
        shouldStopAfterStartup = false
        clearPartialTranscript()
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
        cancelActiveHardwareStart()

        if (recordingState == .transcribing || recordingState == .enhancing),
           let activePipelineTranscriptionID {
            canceledPipelineTranscriptionIDs.insert(activePipelineTranscriptionID)
        }

        cancelCurrentSession()
    }

    private func finishActiveRecorderCancellation() async {
        cancelActiveHardwareStart()
        activeRecordingStartID = nil
        isStartupAudioCaptureActive = false
        isRecordingControlPlaneReady = false
        shouldStopAfterStartup = false
        clearActiveRecordingContext()
        recorder.onAudioChunk = nil
        await recorder.stopRecording()
        await saveCanceledRecording()
        recordedFile = nil
        clearPartialTranscript()
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

    private func cancelActiveHardwareStart() {
        activeHardwareStart?.cancel()
        activeHardwareStart = nil
    }

    private func finishRecorderSession() async {
        enhancementService?.clearCapturedContexts()
    }

    func cleanupResources() async {
        logger.notice("cleanupResources: releasing model resources")
        cancelActiveHardwareStart()
        activeRecordingStartID = nil
        activeRecordingUseCase = .newSession
        isStartupAudioCaptureActive = false
        isRecordingControlPlaneReady = false
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
