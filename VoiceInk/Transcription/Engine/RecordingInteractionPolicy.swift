import Foundation

enum RecorderToggleAction: Equatable {
    case start
    case stopRecording
    case startAssistantFollowUp
    case cancelIdleRecorder
    case ignore
}

enum RecordingInteractionPolicy {
    static func canProcessRecordingShortcut(when state: RecordingState) -> Bool {
        switch state {
        case .idle, .starting, .recording:
            return true
        case .transcribing, .enhancing, .busy:
            return false
        }
    }

    static func toggleAction(
        isRecorderVisible: Bool,
        state: RecordingState,
        canSendAssistantFollowUp: Bool = false
    ) -> RecorderToggleAction {
        if isRecorderVisible {
            switch state {
            case .starting, .recording:
                return .stopRecording
            case .idle:
                return canSendAssistantFollowUp ? .startAssistantFollowUp : .cancelIdleRecorder
            case .transcribing, .enhancing, .busy:
                return .ignore
            }
        }

        switch state {
        case .idle:
            return .start
        case .starting, .recording:
            return .stopRecording
        case .transcribing, .enhancing, .busy:
            return .ignore
        }
    }

    static func shouldDismissPanelAfterStop(
        previousState: RecordingState,
        currentState: RecordingState,
        isRecorderVisible: Bool
    ) -> Bool {
        isRecorderVisible && previousState == .starting && currentState == .idle
    }
}
