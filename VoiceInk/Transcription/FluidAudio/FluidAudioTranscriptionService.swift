import Foundation
import FluidAudio
import os.log

/// Serializes complete operations that mutate or consume the shared FluidAudio
/// managers. Actor isolation alone is insufficient because an actor can reenter
/// while `loadModels`, VAD, or transcription is suspended. Waiting callers are
/// FIFO and a cancelled caller checks cancellation before touching a manager.
actor FluidAudioExclusiveOperationGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var waiterHead = 0

    func run<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async rethrows -> Value {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard waiterHead < waiters.count else {
            waiters.removeAll(keepingCapacity: true)
            waiterHead = 0
            isHeld = false
            return
        }

        let waiter = waiters[waiterHead]
        waiterHead += 1
        if waiterHead == waiters.count {
            waiters.removeAll(keepingCapacity: true)
            waiterHead = 0
        }
        // Ownership transfers directly; isHeld deliberately remains true.
        waiter.resume()
    }
}

actor FluidAudioTranscriptionService: TranscriptionService {
    private var asrManager: AsrManager?
    private var unifiedAsrManager: UnifiedAsrManager?
    private var nemotronAsrManager: StreamingNemotronMultilingualAsrManager?
    private var vadManager: VadManager?
    private var activeVersion: AsrModelVersion?
    private var activeNemotronModelName: String?
    private var cachedModels: AsrModels?
    private var loadingTask: (version: AsrModelVersion, task: Task<AsrModels, Error>)?
    private let operationGate = FluidAudioExclusiveOperationGate()
    private let logger = Logger(subsystem: "com.metrovoc.voiceink.fluidaudio", category: "FluidAudioTranscriptionService")

    private func version(for model: any TranscriptionModel) -> AsrModelVersion {
        FluidAudioModelManager.asrVersion(for: model.name)
    }

    nonisolated static func languageHint(from selectedLanguage: String?, model: any TranscriptionModel) -> Language? {
        guard model.provider == .fluidAudio else {
            return nil
        }
        return FluidAudioModelManager.languageHint(from: selectedLanguage, for: model.name)
    }

    private func cleanupLoadedManagers() async {
        await unifiedAsrManager?.cleanup()
        await nemotronAsrManager?.cleanup()
        await asrManager?.cleanup()

        unifiedAsrManager = nil
        nemotronAsrManager = nil
        asrManager = nil
        vadManager = nil
        activeVersion = nil
        activeNemotronModelName = nil
    }

    private func ensureModelsLoaded(for version: AsrModelVersion) async throws {
        if asrManager != nil, activeVersion == version {
            return
        }

        // Clean up existing manager but preserve cachedModels for reuse
        await cleanupLoadedManagers()

        let models = try await getOrLoadModels(for: version)

        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asrManager = manager
        self.activeVersion = version
    }

    private func ensureUnifiedModelsLoaded() async throws {
        if unifiedAsrManager != nil {
            return
        }

        await cleanupLoadedManagers()

        let manager = UnifiedAsrManager(encoderPrecision: FluidAudioModelManager.parakeetUnifiedPrecision)
        try await manager.loadModels()
        self.unifiedAsrManager = manager
    }

    private func ensureNemotronModelsLoaded(named modelName: String) async throws {
        if nemotronAsrManager != nil, activeNemotronModelName == modelName {
            return
        }

        await cleanupLoadedManagers()

        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadModels(from: FluidAudioModelManager.nemotronCacheDirectory(for: modelName))
        self.nemotronAsrManager = manager
        self.activeNemotronModelName = modelName
    }

    // Returns cached models or loads from disk; deduplicates concurrent loads
    func getOrLoadModels(for version: AsrModelVersion) async throws -> AsrModels {
        if let cached = cachedModels, cached.version == version {
            return cached
        }

        // Deduplicate concurrent loads for the same version
        if let (existingVersion, existingTask) = loadingTask, existingVersion == version {
            return try await existingTask.value
        }

        let task = Task {
            try await AsrModels.downloadAndLoad(
                configuration: nil,
                version: version
            )
        }
        loadingTask = (version, task)

        do {
            let models = try await task.value
            self.cachedModels = models
            // Only clear if we're still the current loading task
            if loadingTask?.version == version {
                self.loadingTask = nil
            }
            return models
        } catch {
            // Only clear if we're still the current loading task
            if loadingTask?.version == version {
                self.loadingTask = nil
            }
            throw error
        }
    }

    func loadModel(for model: any TranscriptionModel) async throws {
        try await operationGate.run { [self] in
            try Task.checkCancellation()
            try await loadModelExclusively(for: model)
        }
    }

    private func loadModelExclusively(for model: any TranscriptionModel) async throws {
        guard model.provider == .fluidAudio else {
            throw ASRError.notInitialized
        }
        if FluidAudioModelManager.isNemotronModel(named: model.name) {
            // Realtime Nemotron uses a dedicated streaming manager; batch loads lazily in transcribe().
            return
        }

        if FluidAudioModelManager.isParakeetUnifiedModel(named: model.name) {
            try await ensureUnifiedModelsLoaded()
            return
        }

        try await ensureModelsLoaded(for: version(for: model))
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws -> String {
        try await operationGate.run { [self] in
            try Task.checkCancellation()
            return try await transcribeExclusively(
                audioURL: audioURL,
                model: model,
                context: context
            )
        }
    }

    private func transcribeExclusively(
        audioURL: URL,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) async throws -> String {
        if FluidAudioModelManager.isParakeetUnifiedModel(named: model.name) {
            try await ensureUnifiedModelsLoaded()
            guard let unifiedAsrManager else {
                throw ASRError.notInitialized
            }

            let speechAudio = try await preparedSpeechAudio(from: audioURL, usesVAD: false)
            let text = try await unifiedAsrManager.transcribe(speechAudio)
            return TextNormalizer.shared.normalizeSentence(text)
        }

        if FluidAudioModelManager.isNemotronModel(named: model.name) {
            try await ensureNemotronModelsLoaded(named: model.name)
            guard let nemotronAsrManager else {
                throw ASRError.notInitialized
            }

            await nemotronAsrManager.reset()
            let compatibleLanguage = TranscriptionLanguageSupport.validLanguageOrFallback(
                context.language,
                for: model
            )
            await nemotronAsrManager.setLanguage(
                FluidAudioModelManager.nemotronLanguageHint(from: compatibleLanguage)
            )

            var speechAudio = try await preparedSpeechAudio(from: audioURL, usesVAD: true)
            let trailingSilenceSamples = 16_000
            let maxSingleChunkSamples = 240_000
            if speechAudio.count + trailingSilenceSamples <= maxSingleChunkSamples {
                speechAudio += [Float](repeating: 0, count: trailingSilenceSamples)
            }

            _ = try await nemotronAsrManager.process(samples: speechAudio)
            let text = try await nemotronAsrManager.finish()
            return TextNormalizer.shared.normalizeSentence(text)
        }

        let targetVersion = version(for: model)
        try await ensureModelsLoaded(for: targetVersion)

        guard let asrManager = asrManager else {
            throw ASRError.notInitialized
        }

        let languageHint = Self.languageHint(
            from: context.language,
            model: model
        )
        var speechAudio = try await preparedSpeechAudio(from: audioURL, usesVAD: true)

        // Pad with 1s of silence to capture final punctuation at sequence boundary
        let trailingSilenceSamples = 16_000
        let maxSingleChunkSamples = 240_000
        if speechAudio.count + trailingSilenceSamples <= maxSingleChunkSamples {
            speechAudio += [Float](repeating: 0, count: trailingSilenceSamples)
        }

        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = try await asrManager.transcribe(
            speechAudio,
            decoderState: &decoderState,
            language: languageHint
        )

        return TextNormalizer.shared.normalizeSentence(result.text)
    }

    private func preparedSpeechAudio(from audioURL: URL, usesVAD: Bool) async throws -> [Float] {
        let audioSamples = try readAudioSamples(from: audioURL)
        let durationSeconds = Double(audioSamples.count) / 16000.0
        let isVADEnabled = UserDefaults.standard.bool(forKey: "IsVADEnabled")

        guard usesVAD, durationSeconds >= 20.0, isVADEnabled else {
            return audioSamples
        }

        let vadConfig = VadConfig(defaultThreshold: 0.7)
        if vadManager == nil {
            do {
                vadManager = try await VadManager(config: vadConfig)
            } catch {
                logger.notice("VAD init failed; falling back to full audio: \(error, privacy: .public)")
                vadManager = nil
            }
        }

        guard let vadManager else {
            return audioSamples
        }

        do {
            let segments = try await vadManager.segmentSpeechAudio(audioSamples)
            return segments.isEmpty ? audioSamples : segments.flatMap { $0 }
        } catch {
            logger.notice("VAD segmentation failed; using full audio: \(error, privacy: .public)")
            return audioSamples
        }
    }

    private func readAudioSamples(from url: URL) throws -> [Float] {
        do {
            let data = try Data(contentsOf: url)
            guard data.count > 44 else {
                throw ASRError.invalidAudioData
            }

            let floats = stride(from: 44, to: data.count, by: 2).map {
                return data[$0..<$0 + 2].withUnsafeBytes {
                    let short = Int16(littleEndian: $0.load(as: Int16.self))
                    return max(-1.0, min(Float(short) / 32767.0, 1.0))
                }
            }

            return floats
        } catch {
            throw ASRError.invalidAudioData
        }
    }

    // Releases ASR/VAD resources but preserves cached models for reuse
    func cleanup() async {
        await operationGate.run { [self] in
            await cleanupLoadedManagers()
        }
    }

}
