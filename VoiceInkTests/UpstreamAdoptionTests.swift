import AppKit
import Foundation
import Testing
@testable import VoiceInk_CE

struct UpstreamAdoptionTests {
    @Test func cartesiaProviderUsesInk2EnglishOnly() {
        let provider = CartesiaProvider()
        let model = provider.models[0]

        #expect(provider.languageCodes == ["en"])
        #expect(provider.includesAutoDetect == false)
        #expect(model.name == "ink-2")
        #expect(model.displayName == "Ink 2")
        #expect(model.isMultilingualModel == false)
        #expect(model.supportedLanguages == ["en": "English"])
    }

    @Test func languageDictionaryFiltersExplicitCodesAndAutoDetect() {
        let languages = LanguageDictionary.forCodes(["en-US", "en-GB"], includesAutoDetect: true)

        #expect(languages["auto"] == "Auto-detect")
        #expect(languages["en-US"] == "English (United States)")
        #expect(languages["en-GB"] == "English (United Kingdom)")
        #expect(languages["fr"] == nil)
    }

    @Test func automaticCleanupScheduleRequiresAudioOnlyCleanup() {
        #expect(
            AutomaticCleanupSchedule.shouldRun(
                isAudioCleanupEnabled: true,
                isTranscriptionCleanupEnabled: false,
                lastCleanupDate: nil
            )
        )

        #expect(
            !AutomaticCleanupSchedule.shouldRun(
                isAudioCleanupEnabled: false,
                isTranscriptionCleanupEnabled: false,
                lastCleanupDate: nil
            )
        )

        #expect(
            !AutomaticCleanupSchedule.shouldRun(
                isAudioCleanupEnabled: true,
                isTranscriptionCleanupEnabled: true,
                lastCleanupDate: nil
            )
        )
    }

    @Test func automaticCleanupScheduleWaitsForFullInterval() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let interval: TimeInterval = 86_400

        #expect(
            !AutomaticCleanupSchedule.shouldRun(
                isAudioCleanupEnabled: true,
                isTranscriptionCleanupEnabled: false,
                lastCleanupDate: now.addingTimeInterval(-(interval - 1)),
                now: now,
                interval: interval
            )
        )

        #expect(
            AutomaticCleanupSchedule.shouldRun(
                isAudioCleanupEnabled: true,
                isTranscriptionCleanupEnabled: false,
                lastCleanupDate: now.addingTimeInterval(-interval),
                now: now,
                interval: interval
            )
        )
    }

    @Test func mainWindowClosePolicyOnlyHidesMainWindow() {
        let mainIdentifier = NSUserInterfaceItemIdentifier("main")

        #expect(
            MainWindowLifecyclePolicy.shouldHideInsteadOfClose(
                windowIdentifier: mainIdentifier,
                mainIdentifier: mainIdentifier
            )
        )
        #expect(
            !MainWindowLifecyclePolicy.shouldHideInsteadOfClose(
                windowIdentifier: NSUserInterfaceItemIdentifier("secondary"),
                mainIdentifier: mainIdentifier
            )
        )
    }

    @Test func accessoryPolicyRestorationRequiresMenuBarOnlyAndNoWindows() {
        #expect(
            MainWindowLifecyclePolicy.shouldRestoreAccessoryPolicy(
                isMenuBarOnly: true,
                hasVisibleNormalWindows: false,
                currentPolicy: .regular
            )
        )
        #expect(
            !MainWindowLifecyclePolicy.shouldRestoreAccessoryPolicy(
                isMenuBarOnly: false,
                hasVisibleNormalWindows: false,
                currentPolicy: .regular
            )
        )
        #expect(
            !MainWindowLifecyclePolicy.shouldRestoreAccessoryPolicy(
                isMenuBarOnly: true,
                hasVisibleNormalWindows: true,
                currentPolicy: .regular
            )
        )
        #expect(
            !MainWindowLifecyclePolicy.shouldRestoreAccessoryPolicy(
                isMenuBarOnly: true,
                hasVisibleNormalWindows: false,
                currentPolicy: .accessory
            )
        )
    }
}
