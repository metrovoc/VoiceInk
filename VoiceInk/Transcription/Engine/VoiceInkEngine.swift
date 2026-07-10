import Foundation
import SwiftUI
import AVFoundation
import SwiftData
import AppKit
import os

final class StartupAudioChunkRelay: @unchecked Sendable {
    struct DrainStats: Sendable {
        let bufferedChunks: Int
        let bufferedBytes: Int
        let droppedChunks: Int
        let droppedBytes: Int
    }

    private let lock = NSLock()
    private let maxBufferedChunks: Int
    private var storage: [Data?]
    private var head = 0
    private var bufferedCount = 0
    private var bufferedBytes = 0
    private var callback: RecordingAudioChunkHandler?
    private var isDraining = false
    private var droppedChunks = 0
    private var droppedBytes = 0

    init(maxBufferedChunks: Int = 600) {
        self.maxBufferedChunks = max(1, maxBufferedChunks)
        self.storage = Array(repeating: nil, count: max(1, maxBufferedChunks))
    }

    func send(_ data: Data) {
        lock.lock()
        if let callback, !isDraining {
            lock.unlock()
            callback(data)
            return
        }

        if bufferedCount == maxBufferedChunks {
            let dropped = storage[head]
            storage[head] = data
            head = (head + 1) % maxBufferedChunks
            droppedChunks += 1
            droppedBytes += dropped?.count ?? 0
            bufferedBytes += data.count - (dropped?.count ?? 0)
        } else {
            let tail = (head + bufferedCount) % maxBufferedChunks
            storage[tail] = data
            bufferedCount += 1
            bufferedBytes += data.count
        }
        lock.unlock()
    }

    func attach(_ callback: @escaping RecordingAudioChunkHandler) -> DrainStats {
        lock.lock()
        self.callback = callback
        isDraining = true
        var chunksToDrain = takeBufferedChunksLocked()
        lock.unlock()

        var drainedChunks = 0
        var drainedBytes = 0

        while true {
            for chunk in chunksToDrain {
                callback(chunk)
                drainedChunks += 1
                drainedBytes += chunk.count
            }

            lock.lock()
            chunksToDrain = takeBufferedChunksLocked()
            if chunksToDrain.isEmpty {
                isDraining = false
                let stats = DrainStats(
                    bufferedChunks: drainedChunks,
                    bufferedBytes: drainedBytes,
                    droppedChunks: droppedChunks,
                    droppedBytes: droppedBytes
                )
                droppedChunks = 0
                droppedBytes = 0
                lock.unlock()
                return stats
            }
            lock.unlock()
        }
    }

    func discard() -> DrainStats {
        lock.lock()
        let stats = DrainStats(
            bufferedChunks: bufferedCount,
            bufferedBytes: bufferedBytes,
            droppedChunks: droppedChunks,
            droppedBytes: droppedBytes
        )
        clearBufferedChunksLocked()
        droppedChunks = 0
        droppedBytes = 0
        callback = nil
        isDraining = false
        lock.unlock()
        return stats
    }

    private func takeBufferedChunksLocked() -> [Data] {
        guard bufferedCount > 0 else { return [] }

        var chunks: [Data] = []
        chunks.reserveCapacity(bufferedCount)
        for offset in 0..<bufferedCount {
            let index = (head + offset) % maxBufferedChunks
            if let chunk = storage[index] {
                chunks.append(chunk)
            }
            storage[index] = nil
        }
        head = 0
        bufferedCount = 0
        bufferedBytes = 0
        return chunks
    }

    private func clearBufferedChunksLocked() {
        for offset in 0..<bufferedCount {
            storage[(head + offset) % maxBufferedChunks] = nil
        }
        head = 0
        bufferedCount = 0
        bufferedBytes = 0
    }
}

/// Moves bounded startup backlog delivery off MainActor. A slow provider
/// callback or several seconds of preconnect audio must never become one long
/// UI frame when the provider finally becomes ready.
enum StartupAudioRelayDrainer {
    static func attach(
        _ relay: StartupAudioChunkRelay,
        callback: @escaping RecordingAudioChunkHandler
    ) async -> StartupAudioChunkRelay.DrainStats {
        return await Task.detached(priority: .userInitiated) {
            relay.attach(callback)
        }.value
    }
}

private final class RecordingModeSettleRace: @unchecked Sendable {
    private let lock = NSLock()
    private var isResolved = false
    private var timeoutTask: Task<Void, Never>?

    func installTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        if isResolved {
            lock.unlock()
            task.cancel()
        } else {
            timeoutTask = task
            lock.unlock()
        }
    }

    func resolve(_ continuation: CheckedContinuation<Bool, Never>, value: Bool) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        let timeoutTask = timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        continuation.resume(returning: value)
    }
}

/// A true wall-clock budget around an independently owned mode-resolution
/// task. Structured task groups are unsuitable here because leaving their
/// scope waits for children even after `cancelAll()`, so an uncooperative URL
/// lookup could silently turn a 120 ms budget into seconds.
enum RecordingModeSettleBudget {
    static func wait(
        for task: Task<Void, Never>,
        nanoseconds: UInt64
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let race = RecordingModeSettleRace()
            Task.detached(priority: .userInitiated) {
                await task.value
                race.resolve(continuation, value: true)
            }

            let timeoutTask = Task.detached(priority: .userInitiated) {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                race.resolve(continuation, value: false)
            }
            race.installTimeoutTask(timeoutTask)
        }
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

enum RecordingGenerationOwnershipPolicy {
    static func owns(activeRecordingID: UUID?, generationID: UUID) -> Bool {
        activeRecordingID == generationID
    }
}

enum RecordingSideLaneModelLoadPolicy {
    /// A live FluidAudio session already owns a dedicated streaming manager.
    /// Loading the batch manager at the same time competes for ANE/CPU without
    /// improving the active path. File-only recording can hide that load safely.
    static func shouldLoadFluidBatchRuntime(
        provider: ModelProvider,
        isRealtimeEnabled: Bool
    ) -> Bool {
        provider == .fluidAudio && !isRealtimeEnabled
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

    /// Immutable ownership captured before finalization reaches its first
    /// suspension point. A user may cancel this generation and start another
    /// recording while hardware stop, provider finalization, or persistence is
    /// still in flight; old work must never reread the new generation's global
    /// fields.
    private struct RecordingGenerationSnapshot {
        let recordingID: UUID
        let audioURL: URL?
        let session: TranscriptionSession?
        let configuration: TranscriptionRuntimeConfiguration?
        let contextCapture: RecordingContextCapture?
        let continuity: RecordingAudioContinuity?
        let trace: RealtimePerformanceTrace?
        let useCase: RecordingUseCase
    }

    @Published var recordingState: RecordingState = .idle
    @Published var shouldCancelRecording = false
    var currentSession: TranscriptionSession?
    private var currentSessionTranscriptionConfiguration: TranscriptionRuntimeConfiguration?
    private var activeRecordingStartID: UUID?
    private var activePipelineTranscriptionID: UUID?
    private var canceledPipelineTranscriptionIDs = Set<UUID>()
    private var canceledRecordingGenerationIDs = Set<UUID>()
    private var activeRecordingUseCase: RecordingUseCase = .newSession
    private var activeHardwareStart: RecordingHardwareStartHandle?
    private var activeRecordingContextCapture: RecordingContextCapture?
    private var activeRecordingTrace: RealtimePerformanceTrace?
    private var activeRecordingAudioContinuity: RecordingAudioContinuity?
    private let finalizationGate = RecordingFinalizationGate()
    private var isStartupAudioCaptureActive = false
    private var isRecordingControlPlaneReady = false
    private var shouldStopAfterStartup = false
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

    private func clearPartialTranscript() {
        recorderUIManager?.clearLiveTranscript()
    }

    private func makeTranscriptSnapshotHandler(
        for startID: UUID
    ) -> @MainActor @Sendable (StreamingTranscriptSnapshot) -> Void {
        { [weak self] snapshot in
            guard let self,
                  self.activeRecordingStartID == startID,
                  self.recordingState == .starting || self.recordingState == .recording else {
                return
            }
            self.recorderUIManager?.applyLiveTranscript(snapshot)
        }
    }

    private func prepareRealtimeSessionIfNeeded(
        configuration: TranscriptionRuntimeConfiguration,
        startID: UUID
    ) async throws -> PreparedRealtimeSession? {
        guard serviceRegistry.shouldUseRealtimeTranscription(for: configuration) else {
            return nil
        }

        let trace = activeRecordingTrace?.sessionID == startID ? activeRecordingTrace : nil
        let session = serviceRegistry.createSession(
            for: configuration,
            onTranscriptSnapshot: makeTranscriptSnapshotHandler(for: startID)
        )
        session.setAudioContinuity(
            activeRecordingAudioContinuity?.sessionID == startID
                ? activeRecordingAudioContinuity
                : nil
        )
        guard let callback = try await session.prepare(configuration: configuration, trace: trace) else {
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

        if activeRecordingTrace?.sessionID == startID {
            activeRecordingTrace?.mark(.preconnectRequested)
        }

        return RecordingRealtimePreconnectLifecycle.begin(
            configuration: configuration,
            startupStartedAt: startupStartedAt,
            prepare: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.prepareRealtimeSessionIfNeeded(
                    configuration: configuration,
                    startID: startID
                )
            },
            onPrepared: { [weak self] configuration, startupElapsed, prepareDuration in
                self?.logger.notice("Recording startup realtime preconnect started model=\(configuration.model.displayName, privacy: .public) elapsed=\(startupElapsed, format: .fixed(precision: 3), privacy: .public)s duration=\(prepareDuration, format: .fixed(precision: 3), privacy: .public)s")
            }
        )
    }

    private func discardEarlyRealtimePreconnect(
        _ preconnect: EarlyRealtimePreconnect?,
        reason: String
    ) {
        guard let preconnect else { return }

        RecordingRealtimePreconnectLifecycle.discard(preconnect) { [weak self] _ in
            self?.logger.notice("Recording startup discarded early realtime session reason=\(reason, privacy: .public)")
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
        RecordingRealtimePreconnectLifecycle.configurationsMatch(lhs, rhs)
    }

    private func waitForStartupModeConfiguration(
        _ task: Task<Void, Never>,
        budgetNanoseconds: UInt64
    ) async -> Bool {
        await RecordingModeSettleBudget.wait(
            for: task,
            nanoseconds: budgetNanoseconds
        )
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
                finishRecorderSession()
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
                activeRecordingTrace?.mark(.stopRequested)
                logger.notice("Stopping recorder while recording control plane prepares")
                recorder.makeHardwareStopper().requestStopRecording()
            case .finishImmediately:
                await finishActiveRecording()
            }
        } else {
            guard recordingState == .idle else {
                logger.notice("Ignoring direct recording start while state is not idle")
                return
            }
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
                    let audioContinuity = RecordingAudioContinuity(sessionID: startID)
                    self.activeRecordingAudioContinuity = audioContinuity
                    let trace = RealtimePerformanceTrace(sessionID: startID)
                    trace.mark(.recordingRequested)
                    self.activeRecordingTrace = trace
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
                    let hardwareStart = self.recorder.beginStartRecording(
                        toOutputFile: permanentURL,
                        continuity: audioContinuity
                    )
                    self.activeHardwareStart = hardwareStart

                    let modeTask = ActiveWindowService.shared.beginApplyingConfiguration(modeId: modeId) { [weak self] in
                        guard let self else { return false }
                        return self.activeRecordingStartID == startID && !self.shouldCancelRecording
                    }

                    // Start provider preparation immediately after issuing the hardware
                    // start. Both operations now overlap instead of serializing network
                    // setup behind audio-device bring-up.
                    let initialRealtimePreconnect = self.beginInitialRealtimePreconnect(
                        startID: startID,
                        startupStartedAt: startupStartedAt
                    )

                    // ActiveWindowService applies its fast app/default decision
                    // synchronously. Capture that trigger-time context before any
                    // recorder UI or asynchronous URL lookup can alter selection.
                    // Preconnect is already scheduled, so optional context work can
                    // never become a dependency of the realtime control plane.
                    self.startRecordingContextCapture(
                        for: ModeManager.shared.currentEffectiveConfiguration
                    )

                    Task { @MainActor [self] in
                        let activeModeTask = modeTask
                        do {
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
                                guard self.activeRecordingStartID == startID else { return }
                                self.recorder.onAudioChunk = nil
                                if self.isRecordingStartCancelled(startID) {
                                    await self.finishActiveRecorderCancellation()
                                } else {
                                    await self.recorder.stopRecording(for: audioContinuity)
                                    guard self.activeRecordingStartID == startID else { return }
                                    try? FileManager.default.removeItem(at: permanentURL)
                                    self.recordedFile = nil
                                    self.recordingState = .idle
                                    self.activeRecordingStartID = nil
                                    self.isStartupAudioCaptureActive = false
                                    self.isRecordingControlPlaneReady = false
                                    self.shouldStopAfterStartup = false
                                    self.clearActiveRecordingContext()
                                    self.cleanupResources()
                                }
                                return
                            }
                            self.isStartupAudioCaptureActive = true
                            trace.mark(.audioCaptureStarted)
                            self.logger.notice("Recording startup audio capture started elapsed=\(startupElapsed(), format: .fixed(precision: 3), privacy: .public)s")
                            self.isStartupAudioCaptureActive = false
                            self.recordingState = .recording
                            self.logger.notice("Recording startup state=recording elapsed=\(startupElapsed(), format: .fixed(precision: 3), privacy: .public)s")

                            guard RecordingStartupContinuationPolicy.shouldContinue(
                                activeRecordingStartID: self.activeRecordingStartID,
                                startID: startID,
                                shouldCancelRecording: self.shouldCancelRecording
                            ) else {
                                _ = startupAudioRelay.discard()
                                guard self.activeRecordingStartID == startID else { return }
                                self.recorder.onAudioChunk = nil
                                if self.isRecordingStartCancelled(startID) {
                                    await self.finishActiveRecorderCancellation()
                                } else {
                                    await self.recorder.stopRecording(for: audioContinuity)
                                    guard self.activeRecordingStartID == startID else { return }
                                    try? FileManager.default.removeItem(at: permanentURL)
                                    self.recordedFile = nil
                                    self.recordingState = .idle
                                    self.activeRecordingStartID = nil
                                    self.isStartupAudioCaptureActive = false
                                    self.isRecordingControlPlaneReady = false
                                    self.shouldStopAfterStartup = false
                                    self.clearActiveRecordingContext()
                                    self.cleanupResources()
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
                                guard self.activeRecordingStartID == startID else { return }
                                self.recorder.onAudioChunk = nil
                                if self.isRecordingStartCancelled(startID) {
                                    await self.finishActiveRecorderCancellation()
                                } else {
                                    await self.recorder.stopRecording(for: audioContinuity)
                                    guard self.activeRecordingStartID == startID else { return }
                                    try? FileManager.default.removeItem(at: permanentURL)
                                    self.recordedFile = nil
                                    self.recordingState = .idle
                                    self.activeRecordingStartID = nil
                                    self.isStartupAudioCaptureActive = false
                                    self.isRecordingControlPlaneReady = false
                                    self.shouldStopAfterStartup = false
                                    self.clearActiveRecordingContext()
                                    self.cleanupResources()
                                }
                                return
                            }

                            guard let transcriptionConfiguration = ModeRuntimeResolver.transcriptionConfiguration(
                                transcriptionModelManager: self.transcriptionModelManager
                            ) else {
                                NotificationManager.shared.showNotification(title: String(localized: "No AI Model Selected"), type: .error)
                                await self.recorder.stopRecording(for: audioContinuity)
                                _ = startupAudioRelay.discard()
                                guard self.activeRecordingStartID == startID else { return }
                                self.recorder.onAudioChunk = nil
                                try? FileManager.default.removeItem(at: permanentURL)
                                self.recordedFile = nil
                                self.recordingState = .idle
                                self.activeRecordingStartID = nil
                                self.isStartupAudioCaptureActive = false
                                self.isRecordingControlPlaneReady = false
                                self.shouldStopAfterStartup = false
                                self.clearActiveRecordingContext()
                                self.cleanupResources()
                                await self.recorderUIManager?.dismissRecorderPanel()
                                return
                            }
                            self.currentSessionTranscriptionConfiguration = transcriptionConfiguration
                            self.reconcileRecordingContextCapture(for: transcriptionConfiguration.mode)
                            self.logger.notice("Recording startup configuration snapshot ready model=\(transcriptionConfiguration.model.displayName, privacy: .public) realtime=\(transcriptionConfiguration.isRealtimeEnabled, privacy: .public) elapsed=\(startupElapsed(), format: .fixed(precision: 3), privacy: .public)s")

                            if let initialRealtimePreconnect {
                                if self.realtimeConfigurationMatches(initialRealtimePreconnect.configuration, transcriptionConfiguration) {
                                    didHandleInitialRealtimePreconnect = true
                                    do {
                                        preparedRealtimeSession = try await initialRealtimePreconnect.task.value
                                        guard RecordingStartupContinuationPolicy.shouldContinue(
                                            activeRecordingStartID: self.activeRecordingStartID,
                                            startID: startID,
                                            shouldCancelRecording: self.shouldCancelRecording
                                        ) else {
                                            throw CancellationError()
                                        }
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

                            let audioChunkCallback: RecordingAudioChunkHandler?
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
                                        onTranscriptSnapshot: self.makeTranscriptSnapshotHandler(
                                            for: startID
                                        )
                                    )
                                    session.setAudioContinuity(audioContinuity)
                                    do {
                                        audioChunkCallback = try await session.prepare(
                                            configuration: transcriptionConfiguration,
                                            trace: trace
                                        )
                                    } catch {
                                        session.cancel()
                                        throw error
                                    }
                                    guard RecordingStartupContinuationPolicy.shouldContinue(
                                        activeRecordingStartID: self.activeRecordingStartID,
                                        startID: startID,
                                        shouldCancelRecording: self.shouldCancelRecording
                                    ) else {
                                        session.cancel()
                                        throw CancellationError()
                                    }
                                    self.currentSession = session
                                    self.logger.notice("Recording startup realtime callback ready elapsed=\(startupElapsed(), format: .fixed(precision: 3), privacy: .public)s")
                                }
                                if let audioChunkCallback {
                                    let drainStats = await StartupAudioRelayDrainer.attach(
                                        startupAudioRelay,
                                        callback: audioChunkCallback
                                    )
                                    self.logger.notice("Recording startup drained pre-session audio chunks=\(drainStats.bufferedChunks, privacy: .public) bytes=\(drainStats.bufferedBytes, privacy: .public) droppedChunks=\(drainStats.droppedChunks, privacy: .public) droppedBytes=\(drainStats.droppedBytes, privacy: .public)")
                                    if drainStats.droppedChunks > 0 {
                                        self.logger.error("Recording startup relay dropped pre-session audio; disabling realtime for this recording droppedChunks=\(drainStats.droppedChunks, privacy: .public) droppedBytes=\(drainStats.droppedBytes, privacy: .public)")
                                        self.cancelCurrentSession(preservingConfiguration: true)
                                        audioContinuity.disableStreamingTracking()
                                        let fallbackSession = FileTranscriptionSession(
                                            service: self.serviceRegistry.service(
                                                for: transcriptionConfiguration.model.provider
                                            )
                                        )
                                        fallbackSession.setAudioContinuity(audioContinuity)
                                        do {
                                            _ = try await fallbackSession.prepare(
                                                configuration: transcriptionConfiguration,
                                                trace: trace
                                            )
                                        } catch {
                                            fallbackSession.cancel()
                                            throw error
                                        }
                                        guard RecordingStartupContinuationPolicy.shouldContinue(
                                            activeRecordingStartID: self.activeRecordingStartID,
                                            startID: startID,
                                            shouldCancelRecording: self.shouldCancelRecording
                                        ) else {
                                            fallbackSession.cancel()
                                            throw CancellationError()
                                        }
                                        self.currentSession = fallbackSession
                                        self.recorder.onAudioChunk = nil
                                    }
                                }
                            } else {
                                let session = self.serviceRegistry.createSession(
                                    for: transcriptionConfiguration
                                )
                                session.setAudioContinuity(audioContinuity)
                                do {
                                    _ = try await session.prepare(
                                        configuration: transcriptionConfiguration,
                                        trace: trace
                                    )
                                } catch {
                                    session.cancel()
                                    throw error
                                }
                                guard RecordingStartupContinuationPolicy.shouldContinue(
                                    activeRecordingStartID: self.activeRecordingStartID,
                                    startID: startID,
                                    shouldCancelRecording: self.shouldCancelRecording
                                ) else {
                                    session.cancel()
                                    throw CancellationError()
                                }
                                self.currentSession = session
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
                                guard self.activeRecordingStartID == startID else { return }
                                self.cancelCurrentSession()
                                if self.isRecordingStartCancelled(startID) {
                                    await self.finishActiveRecorderCancellation()
                                } else {
                                    await self.recorder.stopRecording(for: audioContinuity)
                                    guard self.activeRecordingStartID == startID else { return }
                                    self.recorder.onAudioChunk = nil
                                    try? FileManager.default.removeItem(at: permanentURL)
                                    self.recordedFile = nil
                                    self.recordingState = .idle
                                    self.activeRecordingStartID = nil
                                    self.isStartupAudioCaptureActive = false
                                    self.isRecordingControlPlaneReady = false
                                    self.shouldStopAfterStartup = false
                                    self.clearActiveRecordingContext()
                                    self.cleanupResources()
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
                                       self.whisperModelManager.loadedWhisperModel?.name != currentModel.name {
                                        do {
                                            try await self.whisperModelManager.loadModel(localWhisperModel)
                                        } catch {
                                            self.logger.error("❌ Model loading failed: \(error, privacy: .public)")
                                        }
                                    }
                                } else if RecordingSideLaneModelLoadPolicy
                                    .shouldLoadFluidBatchRuntime(
                                        provider: currentModel.provider,
                                        isRealtimeEnabled: transcriptionConfiguration.isRealtimeEnabled
                                    ) {
                                    // Realtime FluidAudio owns a dedicated live
                                    // manager. Loading a second batch manager
                                    // during capture would contend for ANE/CPU;
                                    // file-only recording can safely hide this
                                    // load behind the recording duration.
                                    try? await self.serviceRegistry.fluidAudioTranscriptionService.loadModel(for: currentModel)
                                }

                            }

                        } catch {
                            activeModeTask.cancel()
                            let isStaleStart = self.activeRecordingStartID != startID
                            let wasCancelled = error is CancellationError
                                || self.isRecordingStartCancelled(startID)
                            if self.activeHardwareStart === hardwareStart {
                                self.activeHardwareStart = nil
                            }
                            // A newer recording or an already-completed cancellation owns
                            // the hardware now. The stale startup must never issue another
                            // stop against that owner.
                            if isStaleStart {
                                return
                            }

                            // Join the same finalization gate as shortcut/UI cancellation.
                            // This closes the race where the startup task and the caller
                            // could both stop hardware and tear down the streaming session.
                            if wasCancelled {
                                await self.finishActiveRecorderCancellation()
                                return
                            }

                            self.cancelCurrentSession()
                            await self.recorder.stopRecording(for: audioContinuity)
                            guard self.activeRecordingStartID == startID else { return }
                            self.recorder.onAudioChunk = nil
                            try? FileManager.default.removeItem(at: permanentURL)
                            self.recordingState = .idle
                            self.recordedFile = nil
                            self.activeRecordingStartID = nil
                            self.isStartupAudioCaptureActive = false
                            self.isRecordingControlPlaneReady = false
                            self.shouldStopAfterStartup = false
                            self.clearActiveRecordingContext()
                            self.cleanupResources()
                            self.logger.error("Recording failed to start: \(error, privacy: .public)")
                            NotificationManager.shared.showNotification(title: String(localized: "Recording failed to start"), type: .error)
                            await self.recorderUIManager?.dismissRecorderPanel()
                        }
                    }
                } else {
                    logger.error("Recording permission denied")
                }
            }
        }
    }

    private func requestRecordPermission(
        response: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
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

    private func startRecordingContextCapture(for mode: ModeConfig?) {
        clearActiveRecordingContext()

        let plan = RecordingContextCapturePlan(mode: mode)
        activeRecordingContextCapture = RecordingContextCaptureService.startCapture(plan: plan)
    }

    private func reconcileRecordingContextCapture(for mode: ModeConfig?) {
        let plan = RecordingContextCapturePlan(mode: mode)

        guard !plan.isEmpty else {
            clearActiveRecordingContext()
            return
        }

        if let activeRecordingContextCapture {
            activeRecordingContextCapture.reconcile(to: plan)
        } else {
            activeRecordingContextCapture = RecordingContextCaptureService.startCapture(plan: plan)
        }
    }

    private func clearActiveRecordingContext() {
        activeRecordingContextCapture?.cancel()
        activeRecordingContextCapture = nil
    }

    // MARK: - Pipeline Dispatch

    private func makeRecordingGenerationSnapshot(
        recordingID: UUID,
        trace: RealtimePerformanceTrace?
    ) -> RecordingGenerationSnapshot {
        RecordingGenerationSnapshot(
            recordingID: recordingID,
            audioURL: recordedFile,
            session: currentSession,
            configuration: currentSessionTranscriptionConfiguration
                ?? ModeRuntimeResolver.transcriptionConfiguration(
                    transcriptionModelManager: transcriptionModelManager
                ),
            contextCapture: activeRecordingContextCapture,
            continuity: activeRecordingAudioContinuity?.sessionID == recordingID
                ? activeRecordingAudioContinuity
                : nil,
            trace: trace,
            useCase: activeRecordingUseCase
        )
    }

    private func ownsRecordingGeneration(
        _ snapshot: RecordingGenerationSnapshot
    ) -> Bool {
        RecordingGenerationOwnershipPolicy.owns(
            activeRecordingID: activeRecordingTrace?.sessionID ?? activeRecordingStartID,
            generationID: snapshot.recordingID
        )
    }

    private func isRecordingGenerationCancelled(
        _ snapshot: RecordingGenerationSnapshot
    ) -> Bool {
        canceledRecordingGenerationIDs.contains(snapshot.recordingID)
            || (ownsRecordingGeneration(snapshot) && shouldCancelRecording)
    }

    private func isRecordingStartCancelled(_ startID: UUID) -> Bool {
        canceledRecordingGenerationIDs.contains(startID)
            || (activeRecordingStartID == startID && shouldCancelRecording)
    }

    private func runPipeline(
        on transcription: Transcription,
        snapshot: RecordingGenerationSnapshot,
        wasPersistedPending: Bool
    ) async {
        let recordingID = snapshot.recordingID
        let audioURL = snapshot.audioURL
        let session = snapshot.session
        let contextCapture = snapshot.contextCapture
        let trace = snapshot.trace
        let useCase = snapshot.useCase

        guard let audioURL, let transcriptionConfiguration = snapshot.configuration else {
            transcription.text = String(localized: "Transcription Failed: No model selected")
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
            if !wasPersistedPending {
                modelContext.insert(transcription)
            }
            try? modelContext.save()
            if !wasPersistedPending {
                NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
            }
            NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
            if ownsRecordingGeneration(snapshot) {
                recordingState = .idle
            }
            canceledRecordingGenerationIDs.remove(recordingID)
            trace?.logSummary()
            return
        }

        let transcriptionID = transcription.id
        if ownsRecordingGeneration(snapshot) {
            activePipelineTranscriptionID = transcriptionID
        }

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
                guard let contextCapture else { return nil }
                return await contextCapture.snapshotAwaitingReadiness()
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
                return self.canceledRecordingGenerationIDs.contains(recordingID)
                    || self.canceledPipelineTranscriptionIDs.contains(transcriptionID)
                    || (self.ownsRecordingGeneration(snapshot) && self.shouldCancelRecording)
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
                isFollowUp: useCase.isAssistantFollowUp,
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
            ),
            performanceTrace: trace,
            wasPersistedPending: wasPersistedPending
        )

        let didFinishActivePipeline = activePipelineTranscriptionID == transcriptionID
            && ownsRecordingGeneration(snapshot)
        if didFinishActivePipeline {
            finishRecorderSession()
            cleanupResources()
            activePipelineTranscriptionID = nil
            currentSession = nil
            currentSessionTranscriptionConfiguration = nil
            if recordedFile == audioURL {
                recordedFile = nil
            }
            shouldCancelRecording = false
            clearActiveRecordingContext()
            trace?.logSummary()
            if activeRecordingTrace === trace {
                activeRecordingTrace = nil
            }
            if activeRecordingAudioContinuity?.sessionID == trace?.sessionID {
                activeRecordingAudioContinuity = nil
            }
        } else {
            contextCapture?.cancel()
        }
        canceledPipelineTranscriptionIDs.remove(transcriptionID)
        canceledRecordingGenerationIDs.remove(recordingID)

        if didFinishActivePipeline &&
            (recordingState == .transcribing || recordingState == .enhancing || recordingState == .busy) {
            recordingState = .idle
        }
    }

    private func finishActiveRecording() async {
        let trace = activeRecordingTrace
        guard let recordingID = trace?.sessionID ?? activeRecordingStartID else {
            logger.notice("Ignoring finalization request without an active recording generation")
            return
        }
        let snapshot = makeRecordingGenerationSnapshot(
            recordingID: recordingID,
            trace: trace
        )
        await finalizationGate.run(recordingID: recordingID) { [weak self] in
            guard let self else { return }

            snapshot.trace?.mark(.stopRequested)

            // Stop capture synchronously. Provider commit is released by the
            // streaming-tail barrier below; clearing the callback here would
            // discard PCM already accepted by the realtime pipe.
            let hardwareStop = self.recorder
                .makeHardwareStopper()
                .requestStopRecording()

            await self.performActiveRecordingFinalization(
                snapshot: snapshot,
                hardwareStop: hardwareStop
            )
        }
    }

    private func performActiveRecordingFinalization(
        snapshot: RecordingGenerationSnapshot,
        hardwareStop: RecordingHardwareStopHandle
    ) async {
        let trace = snapshot.trace
        activeRecordingUseCase = .newSession
        activeRecordingStartID = nil
        isStartupAudioCaptureActive = false
        isRecordingControlPlaneReady = false
        shouldStopAfterStartup = false
        clearPartialTranscript()
        recordingState = .transcribing

        let pendingDraft = snapshot.audioURL.map {
            makePendingRecordingDraft(
                for: $0,
                recordingID: snapshot.recordingID,
                configuration: snapshot.configuration
            )
        }

        // AUHAL is closed before this phase resolves, and the streaming pipe has
        // delivered its complete tail. Commit can now race the file-writer drain
        // without ever manufacturing an avoidable realtime discontinuity.
        await hardwareStop.streamingValue()
        if !isRecordingGenerationCancelled(snapshot) {
            snapshot.session?.requestFinalization(trace: snapshot.trace)
        }

        // Database work starts only after the provider finalization request has
        // crossed the streaming boundary. This ordering is deliberate: even a
        // background ModelContext must never compete with stop-to-commit work.
        let pendingPersistence = pendingDraft.map {
            RecordingPersistenceCoordinator.beginPersistingPending(
                $0,
                in: modelContext.container
            )
        }

        await recorder.stopRecording(for: snapshot.continuity)

        if let continuity = snapshot.continuity {
            let snapshot = continuity.snapshot()
            if snapshot.hasFileDiscontinuity {
                logger.error(
                    "Recording file is incomplete session=\(snapshot.sessionID.uuidString, privacy: .public) droppedChunks=\(snapshot.fileDroppedChunks, privacy: .public) droppedBytes=\(snapshot.fileDroppedBytes, privacy: .public) writeErrors=\(snapshot.fileWriteErrors, privacy: .public)"
                )
            }
        }

        if let recordedFile = snapshot.audioURL {
            let didPersistPending = await pendingPersistence?.value ?? false
            let persistedTranscription = pendingDraft.flatMap { draft in
                didPersistPending
                    ? RecordingPersistenceCoordinator.resolve(id: draft.id, in: modelContext)
                    : nil
            }
            let transcription = persistedTranscription
                ?? pendingDraft?.makeTranscription()
                ?? makeRecordingTranscription(
                    for: recordedFile,
                    text: "",
                    duration: 0,
                    transcriptionStatus: .pending
                )
            let hasDurablePending = didPersistPending && persistedTranscription != nil
            if hasDurablePending {
                NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
            }

            if !isRecordingGenerationCancelled(snapshot) {
                await runPipeline(
                    on: transcription,
                    snapshot: snapshot,
                    wasPersistedPending: hasDurablePending
                )
            } else {
                await saveCanceledRecording(
                    transcription: transcription,
                    audioURL: recordedFile,
                    wasPersistedPending: hasDurablePending
                )
                if ownsRecordingGeneration(snapshot) {
                    if self.recordedFile == recordedFile {
                        self.recordedFile = nil
                    }
                    clearPartialTranscript()
                    if activeRecordingContextCapture === snapshot.contextCapture {
                        clearActiveRecordingContext()
                    } else {
                        snapshot.contextCapture?.cancel()
                    }
                    cleanupResources()
                    finishRecorderSession()
                    if ownsRecordingGeneration(snapshot) {
                        recordingState = .idle
                    }
                } else {
                    snapshot.contextCapture?.cancel()
                }
                trace?.logSummary()
                if activeRecordingTrace === trace {
                    activeRecordingTrace = nil
                }
                if activeRecordingAudioContinuity?.sessionID == trace?.sessionID {
                    activeRecordingAudioContinuity = nil
                }
                canceledRecordingGenerationIDs.remove(snapshot.recordingID)
            }
        } else {
            snapshot.session?.cancel()
            if !isRecordingGenerationCancelled(snapshot) {
                logger.error("❌ No recorded file found after stopping recording")
            }
            if ownsRecordingGeneration(snapshot) {
                recordingState = .idle
                cleanupResources()
                if activeRecordingAudioContinuity?.sessionID == trace?.sessionID {
                    activeRecordingAudioContinuity = nil
                }
            } else {
                snapshot.contextCapture?.cancel()
            }
            canceledRecordingGenerationIDs.remove(snapshot.recordingID)
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
            finishRecorderSession()
        }
    }

    func resetRecordingSession() async {
        if let recordingID = activeRecordingTrace?.sessionID ?? activeRecordingStartID {
            canceledRecordingGenerationIDs.insert(recordingID)
        }
        if let activePipelineTranscriptionID {
            canceledPipelineTranscriptionIDs.insert(activePipelineTranscriptionID)
        }
        cancelActiveHardwareStart()
        cancelCurrentSession()
        activeRecordingStartID = nil
        activePipelineTranscriptionID = nil
        shouldCancelRecording = false
        isStartupAudioCaptureActive = false
        isRecordingControlPlaneReady = false
        shouldStopAfterStartup = false
        clearPartialTranscript()
        assistantSession.reset()
        activeRecordingUseCase = .newSession
        clearActiveRecordingContext()
        await recorder.stopRecording()
        activeRecordingAudioContinuity = nil
        recordedFile = nil
        cleanupResources()
        finishRecorderSession()
        await releaseCachedModelResources()
        recordingState = .idle
    }

    private func requestRecordingCancellation() {
        shouldCancelRecording = true
        cancelActiveHardwareStart()

        if let recordingID = activeRecordingTrace?.sessionID ?? activeRecordingStartID {
            canceledRecordingGenerationIDs.insert(recordingID)
        }

        if (recordingState == .transcribing || recordingState == .enhancing),
           let activePipelineTranscriptionID {
            canceledPipelineTranscriptionIDs.insert(activePipelineTranscriptionID)
        }

        cancelCurrentSession()
    }

    private func finishActiveRecorderCancellation() async {
        shouldCancelRecording = true
        cancelActiveHardwareStart()
        await finishActiveRecording()
    }

    private func saveCanceledRecording(
        transcription: Transcription,
        audioURL: URL,
        wasPersistedPending: Bool
    ) async {
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return }

        let duration = await AudioFileMetadata.duration(for: audioURL)
        transcription.markAsCanceledTranscription(
            duration: duration,
            modelName: transcription.transcriptionModelName
        )

        if !wasPersistedPending {
            modelContext.insert(transcription)
        }

        do {
            try modelContext.save()
            if !wasPersistedPending {
                NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
            }
            NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
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

    private func makePendingRecordingDraft(
        for audioURL: URL,
        recordingID: UUID,
        configuration: TranscriptionRuntimeConfiguration?
    ) -> PendingRecordingDraft {
        let modeMetadata = configuration?.metadata ?? currentModeMetadata()

        return PendingRecordingDraft(
            id: recordingID,
            timestamp: Date(),
            audioFileURL: audioURL.absoluteString,
            transcriptionModelName: configuration?.model.displayName,
            modeName: modeMetadata.name,
            modeEmoji: modeMetadata.emoji
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

    private func finishRecorderSession() {
        enhancementService?.clearCapturedContexts()
    }

    /// Clears only generation-local control state. Model runtimes intentionally
    /// stay hot between recordings; unloading here both adds avoidable latency
    /// to the next trigger and lets an old canceled generation tear resources
    /// out from under a newer one.
    func cleanupResources() {
        cancelActiveHardwareStart()
        activeRecordingStartID = nil
        activeRecordingUseCase = .newSession
        isStartupAudioCaptureActive = false
        isRecordingControlPlaneReady = false
        shouldStopAfterStartup = false
    }

    /// Reserved for launch reset / explicit lifecycle teardown, when the UI is
    /// kept non-idle until release completes. Normal recording finalization
    /// never calls this method.
    private func releaseCachedModelResources() async {
        logger.notice("Releasing cached transcription model resources")
        await whisperModelManager.cleanupResources()
        await serviceRegistry.cleanup()
        logger.notice("Cached transcription model resources released")
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
