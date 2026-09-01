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

    @Test func appDiscoveryDoesNotRecurseThroughDirectorySymlinks() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkAppDiscovery-\(UUID().uuidString)", isDirectory: true)
        let appDirectory = rootURL.appendingPathComponent("Applications", isDirectory: true)
        let linkedDirectory = rootURL.appendingPathComponent("LinkedApplications", isDirectory: true)
        let directApp = appDirectory.appendingPathComponent("Direct.app", isDirectory: true)
        let symlinkedDirectoryApp = linkedDirectory.appendingPathComponent("Hidden.app", isDirectory: true)
        let symlinkTargetApp = linkedDirectory.appendingPathComponent("LinkedTarget.app", isDirectory: true)
        let directorySymlink = appDirectory.appendingPathComponent("LinkedApplications", isDirectory: true)
        let appSymlink = appDirectory.appendingPathComponent("LinkedTarget.app", isDirectory: true)

        try FileManager.default.createDirectory(at: directApp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: symlinkedDirectoryApp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: symlinkTargetApp, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directorySymlink, withDestinationURL: linkedDirectory)
        try FileManager.default.createSymbolicLink(at: appSymlink, withDestinationURL: symlinkTargetApp)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let discoveredPaths = Set(
            InstalledApps.applicationURLs(in: [appDirectory]).map { $0.standardizedFileURL.path }
        )

        #expect(discoveredPaths.contains(directApp.standardizedFileURL.path))
        #expect(discoveredPaths.contains(symlinkTargetApp.standardizedFileURL.path))
        #expect(!discoveredPaths.contains(symlinkedDirectoryApp.standardizedFileURL.path))
    }

    @Test func inputChannelSelectionUsesPreferredStereoChannels() {
        #expect(
            AudioInputChannelSelection.resolve(
                deviceChannelCount: 8,
                preferredStereoChannels: [3, 4]
            ).deviceChannelIndices == [2, 3]
        )

        #expect(
            AudioInputChannelSelection.resolve(
                deviceChannelCount: 4,
                preferredStereoChannels: [3, 3, 4]
            ).deviceChannelIndices == [2, 3]
        )
    }

    @Test func inputChannelSelectionFallsBackForMissingOrInvalidPreferences() {
        #expect(
            AudioInputChannelSelection.resolve(
                deviceChannelCount: 4,
                preferredStereoChannels: nil
            ).deviceChannelIndices == [0, 1]
        )
        #expect(
            AudioInputChannelSelection.resolve(
                deviceChannelCount: 1,
                preferredStereoChannels: nil
            ).deviceChannelIndices == [0]
        )
        #expect(
            AudioInputChannelSelection.resolve(
                deviceChannelCount: 4,
                preferredStereoChannels: [0, 1]
            ).deviceChannelIndices == [0, 1]
        )
        #expect(
            AudioInputChannelSelection.resolve(
                deviceChannelCount: 0,
                preferredStereoChannels: [1, 2]
            ).deviceChannelIndices.isEmpty
        )
    }

    @MainActor
    @Test func modeResolutionDoesNotSubstituteFallbackModelForMissingSelection() {
        let fallback = testTranscriptionModel(name: "fallback", displayName: "Fallback")
        let mode = ModeConfig(
            name: "Dictation",
            isAIEnhancementEnabled: false,
            selectedTranscriptionModelName: "removed-model"
        )

        let resolution = ModeRuntimeResolver.transcriptionModelResolution(
            mode: mode,
            allAvailableModels: [fallback],
            usableModels: [fallback]
        )

        guard case .modelNotFound(_, let modelName) = resolution else {
            Issue.record("Expected missing model resolution")
            return
        }
        #expect(modelName == "removed-model")
        #expect(ModeRuntimeResolver.transcriptionConfiguration(from: resolution) == nil)
    }

    @MainActor
    @Test func modeResolutionRejectsKnownButUnavailableSelectedModel() {
        let selected = testTranscriptionModel(name: "selected", displayName: "Selected")
        let fallback = testTranscriptionModel(name: "fallback", displayName: "Fallback")
        let mode = ModeConfig(
            name: "Dictation",
            isAIEnhancementEnabled: false,
            selectedTranscriptionModelName: selected.name
        )

        let resolution = ModeRuntimeResolver.transcriptionModelResolution(
            mode: mode,
            allAvailableModels: [selected, fallback],
            usableModels: [fallback]
        )

        guard case .unavailable(_, let model) = resolution else {
            Issue.record("Expected unavailable model resolution")
            return
        }
        #expect(model.name == selected.name)
        #expect(ModeRuntimeResolver.transcriptionConfiguration(from: resolution) == nil)
    }

    @MainActor
    @Test func modeResolutionReturnsSelectedUsableModel() throws {
        let selected = testTranscriptionModel(name: "selected", displayName: "Selected")
        let mode = ModeConfig(
            name: "Dictation",
            isAIEnhancementEnabled: false,
            selectedTranscriptionModelName: selected.name,
            selectedLanguage: "fr"
        )

        let resolution = ModeRuntimeResolver.transcriptionModelResolution(
            mode: mode,
            allAvailableModels: [selected],
            usableModels: [selected]
        )
        let configuration = try #require(ModeRuntimeResolver.transcriptionConfiguration(from: resolution))

        #expect(configuration.model.name == selected.name)
        #expect(configuration.language == "fr")
    }

    @Test func enhancementFailureFormatterUsesLocalizedDescription() {
        let description = EnhancementFailureFormatter.description(for: LocalizedEnhancementFailure())

        #expect(description == "Detailed enhancement failure")
        #expect(
            EnhancementFailureFormatter.reEnhancementMessage(description: description)
                == "Re-enhancement failed: Detailed enhancement failure"
        )
    }

    @Test func whisperPromptResolutionUsesSelectedLanguagePrompt() {
        let defaults = UserDefaults.standard
        let key = "CustomLanguagePrompts"
        let original = defaults.object(forKey: key)
        defer { restoreUserDefault(original, forKey: key) }

        defaults.set(["fr": "Bonjour, ceci est un prompt personnalisé."], forKey: key)

        #expect(WhisperPrompt.resolvedPrompt(for: "fr") == "Bonjour, ceci est un prompt personnalisé.")
        #expect(WhisperPrompt.resolvedPrompt(for: "ja").contains("こんにちは"))
        #expect(WhisperPrompt.resolvedPrompt(for: nil).isEmpty)
    }

    @Test func transcriptionRuntimeConfigurationScopesPromptToWhisper() {
        let whisperModel = WhisperModel(
            name: "ggml-test",
            displayName: "Whisper Test",
            size: "1 MB",
            supportedLanguages: ["de": "German"],
            description: "Test model",
            speed: 1,
            accuracy: 1,
            ramUsage: 1
        )
        let whisperConfiguration = TranscriptionRuntimeConfiguration(
            mode: nil,
            model: whisperModel,
            language: "de",
            isRealtimeEnabled: false
        )
        let cloudConfiguration = TranscriptionRuntimeConfiguration(
            mode: nil,
            model: testTranscriptionModel(name: "deepgram-test", displayName: "Deepgram Test"),
            language: "de",
            isRealtimeEnabled: false
        )

        #expect(whisperConfiguration.requestContext.prompt == WhisperPrompt.resolvedPrompt(for: "de"))
        #expect(whisperConfiguration.requestContext.prompt?.isEmpty == false)
        #expect(cloudConfiguration.requestContext.prompt == nil)
    }

    @Test func openAIEnhancementCatalogIncludesGPT56Models() {
        #expect(AIProvider.openAI.defaultModel == "gpt-5.6-luna")
        #expect(Array(AIProvider.openAI.availableModels.prefix(3)) == [
            "gpt-5.6-luna",
            "gpt-5.6-terra",
            "gpt-5.6-sol"
        ])
        #expect(ReasoningConfig.getReasoningParameter(for: .openAI, modelName: "gpt-5.6-luna") == "none")
        #expect(ReasoningConfig.getReasoningParameter(for: .openAI, modelName: "gpt-5.6-terra") == "none")
        #expect(ReasoningConfig.getReasoningParameter(for: .openAI, modelName: "gpt-5.6-sol") == "none")
    }

    @Test func recorderEscapeTimeoutUsesGenerationGuard() throws {
        let source = try readProjectSource("VoiceInk/Shortcuts/RecorderPanelShortcutManager.swift")

        #expect(source.contains("private var activeEscapePressID: UUID?"))
        #expect(source.contains("let escapePressID = UUID()"))
        #expect(source.contains("guard self?.activeEscapePressID == escapePressID else { return }"))
        #expect(source.contains("self?.escapeTimeoutTask = nil"))
    }

    private func testTranscriptionModel(name: String, displayName: String) -> CloudModel {
        CloudModel(
            name: name,
            displayName: displayName,
            description: "Test model",
            provider: .deepgram,
            speed: 1,
            accuracy: 1,
            isMultilingual: true,
            supportedLanguages: ["en": "English", "fr": "French"]
        )
    }

    private func readProjectSource(_ relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func restoreUserDefault(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

private struct LocalizedEnhancementFailure: LocalizedError {
    var errorDescription: String? {
        "Detailed enhancement failure"
    }
}
