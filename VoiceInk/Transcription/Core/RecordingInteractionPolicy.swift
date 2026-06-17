import Foundation

enum RecorderToggleAction: Equatable {
    case start
    case stopRecording
    case cancelIdleRecorder
    case ignore
}

enum RecordingInteractionPolicy {
    static func canProcessHotkeyAction(when state: RecordingState) -> Bool {
        switch state {
        case .idle, .recording:
            return true
        case .starting, .transcribing, .enhancing, .busy:
            return false
        }
    }

    static func toggleAction(isRecorderVisible: Bool, state: RecordingState) -> RecorderToggleAction {
        if isRecorderVisible {
            switch state {
            case .recording:
                return .stopRecording
            case .idle:
                return .cancelIdleRecorder
            case .starting, .transcribing, .enhancing, .busy:
                return .ignore
            }
        }

        switch state {
        case .idle:
            return .start
        case .recording:
            return .stopRecording
        case .starting, .transcribing, .enhancing, .busy:
            return .ignore
        }
    }
}
