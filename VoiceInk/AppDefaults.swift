import Foundation
import OSLog

enum AppIdentity {
    static let bundleIdentifier = "com.metrovoc.VoiceInk"
    static let legacyBundleIdentifier = "com.prakashjoshipax.VoiceInk"
    static let cloudKitContainerIdentifier = "iCloud.com.metrovoc.VoiceInk"
    static let loggerSubsystem = "com.metrovoc.voiceink"
}

enum AppPaths {
    static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.bundleIdentifier, isDirectory: true)
    }

    static var legacyApplicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.legacyBundleIdentifier, isDirectory: true)
    }

    static var recordingsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }

    static var modelsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("WhisperModels", isDirectory: true)
    }

    static func ensureApplicationSupportDirectoryExists(logger: Logger) throws {
        let fileManager = FileManager.default
        let currentDirectory = applicationSupportDirectory
        let legacyDirectory = legacyApplicationSupportDirectory

        if !fileManager.fileExists(atPath: currentDirectory.path), fileManager.fileExists(atPath: legacyDirectory.path) {
            try fileManager.moveItem(at: legacyDirectory, to: currentDirectory)
            logger.notice("Migrated Application Support directory to \(currentDirectory.path, privacy: .public)")
        }

        try fileManager.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
    }
}

enum AppDefaults {
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            // Onboarding & General
            "hasCompletedOnboarding": false,
            "enableAnnouncements": true,
            "autoUpdateCheck": true,

            // Clipboard
            "restoreClipboardAfterPaste": true,
            "clipboardRestoreDelay": 2.0,
            "useAppleScriptPaste": false,

            // Audio & Media
            "isSystemMuteEnabled": true,
            "audioResumptionDelay": 0.0,
            "isPauseMediaEnabled": false,
            "isSoundFeedbackEnabled": true,

            // Recording & Transcription
            "IsTextFormattingEnabled": true,
            "IsVADEnabled": true,
            "RemoveFillerWords": true,
            "SelectedLanguage": "en",
            "AppendTrailingSpace": true,
            "RecorderType": "mini",

            // Cleanup
            "IsTranscriptionCleanupEnabled": false,
            "TranscriptionRetentionMinutes": 1440,
            "IsAudioCleanupEnabled": false,
            "AudioRetentionPeriod": 7,

            // UI & Behavior
            "IsMenuBarOnly": false,
            "powerModeAutoRestoreEnabled": false,
            // Hotkey
            "isMiddleClickToggleEnabled": false,
            "middleClickActivationDelay": 200,

            // Enhancement
            "isToggleEnhancementShortcutEnabled": true,
            "SkipShortEnhancement": true,
            "ShortEnhancementWordThreshold": 3,
            "EnhancementTimeoutSeconds": 7,
            "EnhancementRetryOnTimeout": true,

            // Model
            "PrewarmModelOnWake": true,

        ])
    }
}
