import Foundation
import SwiftUI
import os
#if DEBUG
import Darwin
#endif

enum RecorderPanelStyle: String, CaseIterable, Identifiable {
    case notch
    case mini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notch:
            return String(localized: "Notch")
        case .mini:
            return String(localized: "Mini")
        }
    }

    static var stored: RecorderPanelStyle {
        let rawValue = UserDefaults.standard.string(forKey: "RecorderType") ?? RecorderPanelStyle.mini.rawValue
        return RecorderPanelStyle(rawValue: rawValue) ?? .mini
    }
}

@MainActor
protocol RecorderPanelPresenting: AnyObject {
    var isRecorderPanelVisible: Bool { get }
    func applyLiveTranscript(_ snapshot: StreamingTranscriptSnapshot)
    func clearLiveTranscript()
    func dismissRecorderPanel() async
}

@MainActor
class RecorderUIManager: ObservableObject, RecorderPanelPresenting {
    @Published var recorderPanelStyle: RecorderPanelStyle = .stored {
        didSet {
            guard oldValue != recorderPanelStyle else { return }
            rebuildVisiblePanel(previousStyle: oldValue)
            UserDefaults.standard.set(recorderPanelStyle.rawValue, forKey: "RecorderType")
            if !isRecorderPanelVisible {
                destroyPanel(style: oldValue)
                prepareRecorderPanel()
            }
        }
    }

    var recorderType: String {
        get { recorderPanelStyle.rawValue }
        set { recorderPanelStyle = RecorderPanelStyle(rawValue: newValue) ?? .mini }
    }

    @Published var isRecorderPanelVisible = false {
        didSet {
            guard oldValue != isRecorderPanelVisible else { return }

            if isRecorderPanelVisible {
                showRecorderPanel()
            } else {
                hideRecorderPanel()
            }
        }
    }

    private var notchWindowManager: NotchWindowManager?
    private var miniWindowManager: MiniWindowManager?

    private weak var engine: VoiceInkEngine?
    private var recorder: Recorder?
    private var presentationModel: RecorderPresentationModel?

    private let logger = Logger(subsystem: "com.metrovoc.voiceink", category: "RecorderUIManager")
    #if DEBUG
    private var debugToggleSignalSource: DispatchSourceSignal?
    #endif

    init() {}

    /// Call after VoiceInkEngine is created to break the circular init dependency.
    func configure(engine: VoiceInkEngine, recorder: Recorder) {
        self.engine = engine
        self.recorder = recorder
        presentationModel = RecorderPresentationModel(engine: engine)
        setupNotifications()
        prepareRecorderPanel()
    }

    // MARK: - Recorder Panel Management

    func prepareRecorderPanel() {
        guard let engine = engine, let recorder = recorder else { return }

        switch recorderPanelStyle {
        case .notch:
            notchWindowManager(for: engine, recorder: recorder).prepare()
        case .mini:
            miniWindowManager(for: engine, recorder: recorder).prepare()
        }
    }

    private func showRecorderPanel() {
        guard let engine = engine, let recorder = recorder else { return }

        switch recorderPanelStyle {
        case .notch:
            notchWindowManager(for: engine, recorder: recorder).show()
        case .mini:
            miniWindowManager(for: engine, recorder: recorder).show()
        }
    }

    private func notchWindowManager(for engine: VoiceInkEngine, recorder: Recorder) -> NotchWindowManager {
        if let notchWindowManager {
            return notchWindowManager
        }

        guard let presentationModel else {
            preconditionFailure("RecorderUIManager must be configured before creating a panel")
        }
        let manager = NotchWindowManager(
            presentation: presentationModel,
            recorder: recorder,
            assistantSession: engine.assistantSession,
            onRecordButtonTapped: { [weak self] in
                Task { @MainActor in
                    await self?.toggleRecorderPanel()
                }
            },
            onCloseTapped: { [weak self] in
                Task { @MainActor in
                    await self?.dismissRecorderPanel()
                }
            },
            onAssistantFollowUp: { [weak engine] text in
                Task { @MainActor in
                    await engine?.sendAssistantFollowUp(text)
                }
            }
        )
        notchWindowManager = manager
        return manager
    }

    private func miniWindowManager(for engine: VoiceInkEngine, recorder: Recorder) -> MiniWindowManager {
        if let miniWindowManager {
            return miniWindowManager
        }

        guard let presentationModel else {
            preconditionFailure("RecorderUIManager must be configured before creating a panel")
        }
        let manager = MiniWindowManager(
            presentation: presentationModel,
            recorder: recorder,
            assistantSession: engine.assistantSession,
            onRecordButtonTapped: { [weak self] in
                Task { @MainActor in
                    await self?.toggleRecorderPanel()
                }
            },
            onCloseTapped: { [weak self] in
                Task { @MainActor in
                    await self?.dismissRecorderPanel()
                }
            },
            onAssistantFollowUp: { [weak engine] text in
                Task { @MainActor in
                    await engine?.sendAssistantFollowUp(text)
                }
            }
        )
        miniWindowManager = manager
        return manager
    }

    private func hideRecorderPanel() {
        switch recorderPanelStyle {
        case .notch:
            notchWindowManager?.hide()
        case .mini:
            miniWindowManager?.hide()
        }
    }

    private func destroyPanel(style: RecorderPanelStyle) {
        switch style {
        case .notch:
            notchWindowManager?.destroyWindow()
            notchWindowManager = nil
        case .mini:
            miniWindowManager?.destroyWindow()
            miniWindowManager = nil
        }
    }

    private func rebuildVisiblePanel(previousStyle: RecorderPanelStyle) {
        guard isRecorderPanelVisible else { return }

        destroyPanel(style: previousStyle)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            showRecorderPanel()
        }
    }

    // MARK: - Recorder Panel Management

    func toggleRecorderPanel(modeId: UUID? = nil) async {
        guard let engine = engine else { return }

        switch RecordingInteractionPolicy.toggleAction(
            isRecorderVisible: isRecorderPanelVisible,
            state: engine.recordingState,
            canSendAssistantFollowUp: engine.assistantSession.canSendFollowUp
        ) {
        case .start:
            await engine.toggleRecord(modeId: modeId)
            SoundManager.shared.playStartSound()
            isRecorderPanelVisible = true
        case .stopRecording:
            let previousState = engine.recordingState
            await engine.toggleRecord(modeId: modeId)
            if RecordingInteractionPolicy.shouldDismissPanelAfterStop(
                previousState: previousState,
                currentState: engine.recordingState,
                isRecorderVisible: isRecorderPanelVisible
            ) {
                await dismissRecorderPanel()
            }
        case .startAssistantFollowUp:
            SoundManager.shared.playStartSound()
            await engine.toggleRecord(
                modeId: modeId,
                isAssistantFollowUp: true
            )
        case .cancelIdleRecorder:
            await dismissRecorderPanel()
        case .ignore:
            return
        }
    }

    func dismissRecorderPanel() async {
        guard let engine = engine else { return }

        hideRecorderPanel()
        isRecorderPanelVisible = false
        engine.assistantSession.reset()
    }

    func applyLiveTranscript(_ snapshot: StreamingTranscriptSnapshot) {
        presentationModel?.applyLiveTranscript(snapshot)
    }

    func clearLiveTranscript() {
        presentationModel?.clearLiveTranscript()
    }

    func resetOnLaunch() async {
        guard let engine = engine else { return }
        logger.notice("Resetting recording state on launch")
        await engine.resetRecordingSession()
        hideRecorderPanel()
        isRecorderPanelVisible = false
        engine.assistantSession.reset()
    }

    func cancelRecording() async {
        guard let engine = engine else { return }
        await engine.cancelRecording()
        await dismissRecorderPanel()
    }

    // MARK: - Notification Handling

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleRecorderPanelNotification),
            name: .toggleRecorderPanel,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDismissRecorderPanelNotification),
            name: .dismissRecorderPanel,
            object: nil
        )

        #if DEBUG
        setupDebugSignalHandler()
        #endif
    }

    #if DEBUG
    private func setupDebugSignalHandler() {
        guard debugToggleSignalSource == nil else { return }
        signal(SIGUSR1, SIG_IGN)

        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.logger.notice("Debug recording toggle signal received")
                await self.toggleRecorderPanel()
            }
        }
        source.resume()
        debugToggleSignalSource = source
        logger.notice("Registered debug recording toggle signal handler signal=SIGUSR1")
    }
    #endif

    @objc public func handleToggleRecorderPanelNotification() {
        Task {
            await toggleRecorderPanel()
        }
    }

    @objc public func handleDismissRecorderPanelNotification() {
        Task {
            switch engine?.recordingState {
            case .starting, .recording, .transcribing, .enhancing:
                await cancelRecording()
            case .idle, .busy, nil:
                await dismissRecorderPanel()
            }
        }
    }
}
