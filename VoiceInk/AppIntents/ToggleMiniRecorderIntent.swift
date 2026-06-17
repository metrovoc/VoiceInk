import AppIntents
import Foundation
import AppKit

struct ToggleMiniRecorderIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle VoiceInk CE Recorder"
    static var description = IntentDescription("Start or stop the VoiceInk CE recorder for voice transcription.")
    
    static var openAppWhenRun: Bool = false
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .toggleRecorderPanel, object: nil)
        
        let dialog: IntentDialog = "VoiceInk CE recorder toggled"
        return .result(dialog: dialog)
    }
}

enum IntentError: Error, LocalizedError {
    case appNotAvailable
    case serviceNotAvailable
    
    var errorDescription: String? {
        switch self {
        case .appNotAvailable:
            return String(localized: "VoiceInk CE app is not available")
        case .serviceNotAvailable:
            return String(localized: "VoiceInk CE recording service is not available")
        }
    }
}
