import FluidAudio
import Foundation
import os

/// Agreement-based on-device streaming transcription using FluidAudio ASR.
///
/// The provider retains only the unconfirmed PCM tail. Audio is addressed by
/// absolute sample offset in a fixed-capacity segmented store, so a long
/// recording neither shifts arrays nor grows resident memory with duration.
final class FluidAudioStreamingProvider: StreamingTranscriptionProvider, @unchecked Sendable {
    typealias TestingTranscriber = @Sendable ([Float]) async throws -> ASRResult

    private let logger = Logger(
        subsystem: AppIdentity.loggerSubsystem,
        category: "FluidAudioStreaming"
    )
    private let fluidAudioService: FluidAudioTranscriptionService?
    private let testingTranscriber: TestingTranscriber?
    private var eventsContinuation: StreamingProviderEventRelay?

    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    private let sampleRate = ASRConstants.sampleRate
    private let maximumASRWindowSamples: Int
    private let trailingSilenceSamples = ASRConstants.sampleRate
    private let pcmBuffer: SegmentedPCMBuffer

    private var asrManager: AsrManager?
    private var decoderLayerCount = 0
    private var languageHint: Language?
    private let agreementEngine: WordAgreementEngine
    private let config: AgreementConfig

    private var transcriptionTask: Task<Void, Never>?
    private var isTranscribing = false
    private var lastTranscribedSampleOffset: Int64 = 0
    private let minimumAudioSamples = ASRConstants.minimumRequiredSamples(
        forSampleRate: ASRConstants.sampleRate
    )
    private let minNewSamples = ASRConstants.minimumRequiredSamples(
        forSampleRate: ASRConstants.sampleRate
    )

    private let failureLock = NSLock()
    private var terminalFailure: Error?

    init(
        fluidAudioService: FluidAudioTranscriptionService,
        config: AgreementConfig = AgreementConfig(),
        maximumASRWindowSamples: Int = ASRConstants.maxModelSamples,
        pcmBlockSize: Int = 4_096
    ) {
        self.fluidAudioService = fluidAudioService
        self.testingTranscriber = nil
        self.config = config
        self.maximumASRWindowSamples = maximumASRWindowSamples
        self.pcmBuffer = SegmentedPCMBuffer(
            maximumRetainedSamples: maximumASRWindowSamples,
            blockSize: pcmBlockSize
        )
        self.agreementEngine = WordAgreementEngine(config: config)

        let relay = StreamingProviderEventRelay()
        transcriptionEvents = relay.stream
        eventsContinuation = relay
    }

    /// Model-free initializer for deterministic provider lifecycle tests.
    init(
        config: AgreementConfig = AgreementConfig(),
        maximumASRWindowSamples: Int = ASRConstants.maxModelSamples,
        pcmBlockSize: Int = 4_096,
        testingTranscriber: @escaping TestingTranscriber
    ) {
        self.fluidAudioService = nil
        self.testingTranscriber = testingTranscriber
        self.config = config
        self.maximumASRWindowSamples = maximumASRWindowSamples
        self.pcmBuffer = SegmentedPCMBuffer(
            maximumRetainedSamples: maximumASRWindowSamples,
            blockSize: pcmBlockSize
        )
        self.agreementEngine = WordAgreementEngine(config: config)

        let relay = StreamingProviderEventRelay()
        transcriptionEvents = relay.stream
        eventsContinuation = relay
    }

    deinit {
        transcriptionTask?.cancel()
        eventsContinuation?.finish()
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        if testingTranscriber == nil {
            guard let fluidAudioService else {
                throw StreamingTranscriptionError.notConnected
            }
            let version = FluidAudioModelManager.asrVersion(for: model.name)
            let models = try await fluidAudioService.getOrLoadModels(for: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asrManager = manager
            decoderLayerCount = await manager.decoderLayerCount
            languageHint = FluidAudioTranscriptionService.languageHint(
                from: language,
                model: model
            )
        } else {
            asrManager = nil
            decoderLayerCount = 0
            languageHint = nil
        }

        resetFailure()
        agreementEngine.reset()
        pcmBuffer.reset()
        lastTranscribedSampleOffset = 0
        startTranscriptionLoop()

        eventsContinuation?.yield(.sessionStarted)
        logger.notice(
            "FluidAudio agreement streaming started for \(model.displayName, privacy: .public) maxWindowSamples=\(self.maximumASRWindowSamples, privacy: .public)"
        )
    }

    func sendAudioChunk(_ data: Data) async throws {
        try throwIfFailed()
        let samples = PCMAudioConverter.float32Samples(fromPCM16Data: data)
        do {
            try pcmBuffer.append(samples)
        } catch let bufferError as SegmentedPCMBuffer.BufferError {
            let error = makeWindowExceededError(bufferError)
            recordAndPublishFailure(error)
            throw error
        }
    }

    func commit() async throws {
        transcriptionTask?.cancel()
        await transcriptionTask?.value
        transcriptionTask = nil
        try throwIfFailed()

        do {
            // A final clean pass covers exactly the still-unconfirmed tail.
            let remainingText = try await transcribeRemainingAudio() ?? ""
            eventsContinuation?.yield(.committed(text: remainingText))
            eventsContinuation?.yield(.finalized)
        } catch {
            recordAndPublishFailure(error)
            throw error
        }
    }

    func disconnect() async {
        transcriptionTask?.cancel()
        await transcriptionTask?.value
        transcriptionTask = nil

        await asrManager?.cleanup()
        asrManager = nil
        decoderLayerCount = 0
        languageHint = nil

        pcmBuffer.reset()
        agreementEngine.reset()
        resetFailure()

        eventsContinuation?.finish()
        logger.notice("FluidAudio agreement streaming disconnected")
    }

    var pcmBufferSnapshot: SegmentedPCMBuffer.Snapshot {
        pcmBuffer.snapshot()
    }

    // MARK: - Private

    private func startTranscriptionLoop() {
        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(
                        (self?.config.transcribeIntervalSeconds ?? 1.0) * 1_000_000_000
                    ))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await self?.runTranscriptionPass()
            }
        }
    }

    private func runTranscriptionPass() async {
        guard !isTranscribing, currentFailure() == nil else { return }

        let snapshot = pcmBuffer.snapshot()
        let absoluteSampleEnd = snapshot.retainedRange.upperBound
        guard absoluteSampleEnd - lastTranscribedSampleOffset >= Int64(minNewSamples) else {
            return
        }

        let seekSample = unconfirmedStartSample()
        guard absoluteSampleEnd - seekSample >= Int64(minimumAudioSamples) else { return }

        let window: SegmentedPCMBuffer.Window
        do {
            guard let availableWindow = try pcmBuffer.window(
                from: seekSample,
                through: absoluteSampleEnd,
                maximumSamples: maximumASRWindowSamples
            ) else { return }
            window = availableWindow
        } catch let bufferError as SegmentedPCMBuffer.BufferError {
            recordAndPublishFailure(makeWindowExceededError(bufferError))
            return
        } catch {
            recordAndPublishFailure(error)
            return
        }

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            let result = try await transcribe(paddedForASR(window.samples))
            lastTranscribedSampleOffset = window.range.upperBound

            guard let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty else {
                let hypothesis = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !hypothesis.isEmpty {
                    eventsContinuation?.yield(.partial(text: hypothesis))
                }
                return
            }

            let timeOffset = Double(window.range.lowerBound) / Double(sampleRate)
            let words = WordAgreementEngine.mergeTokensToWords(
                tokenTimings,
                timeOffset: timeOffset
            )
            guard !words.isEmpty else { return }

            let agreementResult = agreementEngine.processTranscriptionResult(
                words: words,
                resultConfidence: result.confidence
            )

            if !agreementResult.newlyConfirmedText.isEmpty {
                let normalizedConfirmed = TextNormalizer.shared.normalizeSentence(
                    agreementResult.newlyConfirmedText
                )
                eventsContinuation?.yield(.committed(text: normalizedConfirmed))
            }
            if !agreementResult.hypothesisText.isEmpty {
                // Contract: partial is only the mutable uncommitted tail.
                eventsContinuation?.yield(.partial(text: agreementResult.hypothesisText))
            }

            let safeTrimPoint = unconfirmedStartSample()
            if safeTrimPoint > snapshot.retainedRange.lowerBound {
                pcmBuffer.discard(before: safeTrimPoint)
            }
        } catch {
            logger.error("Transcription pass failed: \(error, privacy: .public)")
            recordAndPublishFailure(error)
        }
    }

    /// Final transcription of audio after the last confirmed word.
    private func transcribeRemainingAudio() async throws -> String? {
        let seekSample = unconfirmedStartSample()
        let absoluteSampleEnd = pcmBuffer.snapshot().retainedRange.upperBound
        guard let window = try pcmBuffer.window(
            from: seekSample,
            through: absoluteSampleEnd,
            maximumSamples: maximumASRWindowSamples
        ) else { return nil }

        guard window.samples.count >= minimumAudioSamples else { return nil }
        let result = try await transcribe(paddedForASR(window.samples))
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return TextNormalizer.shared.normalizeSentence(text)
    }

    private func transcribe(_ samples: [Float]) async throws -> ASRResult {
        precondition(
            samples.count <= maximumASRWindowSamples,
            "FluidAudio ASR input exceeded its explicit window"
        )
        if let testingTranscriber {
            return try await testingTranscriber(samples)
        }
        guard let asrManager else {
            throw StreamingTranscriptionError.notConnected
        }
        var state = TdtDecoderState.make(decoderLayers: decoderLayerCount)
        return try await asrManager.transcribe(
            samples,
            decoderState: &state,
            language: languageHint
        )
    }

    private func paddedForASR(_ samples: [Float]) -> [Float] {
        guard samples.count + trailingSilenceSamples <= maximumASRWindowSamples else {
            return samples
        }
        var padded = samples
        padded.append(contentsOf: repeatElement(0, count: trailingSilenceSamples))
        return padded
    }

    private func unconfirmedStartSample() -> Int64 {
        let seekTime = agreementEngine.hypothesisStartTime > 0
            ? agreementEngine.hypothesisStartTime
            : agreementEngine.confirmedEndTime
        return max(0, Int64(seekTime * Double(sampleRate)))
    }

    private func makeWindowExceededError(
        _ error: SegmentedPCMBuffer.BufferError
    ) -> StreamingTranscriptionError {
        logger.error("FluidAudio realtime retention failed: \(String(describing: error), privacy: .public)")
        return .transcriptionWindowExceeded(
            maximumDuration: Double(maximumASRWindowSamples) / Double(sampleRate)
        )
    }

    private func recordAndPublishFailure(_ error: Error) {
        let shouldPublish: Bool
        failureLock.lock()
        if terminalFailure == nil {
            terminalFailure = error
            shouldPublish = true
        } else {
            shouldPublish = false
        }
        failureLock.unlock()

        if shouldPublish {
            eventsContinuation?.yield(.error(error))
        }
    }

    private func throwIfFailed() throws {
        if let failure = currentFailure() {
            throw failure
        }
    }

    private func currentFailure() -> Error? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return terminalFailure
    }

    private func resetFailure() {
        failureLock.lock()
        terminalFailure = nil
        failureLock.unlock()
    }
}
