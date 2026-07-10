import SwiftUI
import AppKit

@MainActor
class NotchWindowManager {
    private var windowController: NSWindowController?
    private var panel: NotchRecorderPanel?
    private var metricsModel: NotchRecorderMetricsModel?

    private let makeView: (NotchRecorderMetricsModel) -> AnyView

    init(
        presentation: RecorderPresentationModel,
        recorder: Recorder,
        assistantSession: AssistantSession,
        onRecordButtonTapped: @escaping () -> Void,
        onCloseTapped: @escaping () -> Void,
        onAssistantFollowUp: @escaping (String) -> Void
    ) {
        self.makeView = { metricsModel in
            AnyView(
                NotchRecorderView(
                    presentation: presentation,
                    audioMeterSource: recorder.audioMeterSource,
                    assistantSession: assistantSession,
                    metrics: metricsModel,
                    onRecordButtonTapped: onRecordButtonTapped,
                    onCloseTapped: onCloseTapped,
                    onAssistantFollowUp: onAssistantFollowUp
                )
            )
        }
    }

    func prepare() {
        if panel == nil { initializeWindow() }
    }

    func show() {
        prepare()
        panel?.show()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func destroyWindow() {
        deinitializeWindow()
    }

    private func initializeWindow() {
        deinitializeWindow()
        let metrics = NotchRecorderPanel.calculateWindowMetrics()
        let newMetricsModel = NotchRecorderMetricsModel(metrics: metrics)
        let newPanel = NotchRecorderPanel(contentRect: metrics.frame)
        newPanel.onMetricsChanged = { [weak newMetricsModel] metrics in
            newMetricsModel?.update(metrics)
        }
        let view = makeView(newMetricsModel)
        let hostingController = NotchRecorderHostingController(rootView: view)
        newPanel.contentView = hostingController.view
        metricsModel = newMetricsModel
        panel = newPanel
        windowController = NSWindowController(window: newPanel)
    }

    private func deinitializeWindow() {
        panel?.orderOut(nil)
        windowController?.close()
        windowController = nil
        panel = nil
        metricsModel = nil
    }

}
