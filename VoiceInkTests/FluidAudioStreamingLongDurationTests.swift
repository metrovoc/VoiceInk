import FluidAudio
import Foundation
import Testing
@testable import VoiceInk_CE

@Suite(.serialized)
struct FluidAudioStreamingLongDurationTests {
    @Test func segmentedPCMBufferKeepsConstantMemoryAcrossOneHourOfSamples() throws {
        let sampleRate = 16_000
        let buffer = SegmentedPCMBuffer(
            maximumRetainedSamples: 240_000,
            blockSize: 4_096
        )
        let oneSecond = [Float](repeating: 0.25, count: sampleRate)
        let retainedTail = sampleRate * 2

        for _ in 0..<3_600 {
            _ = try buffer.append(oneSecond)
            let end = buffer.snapshot().retainedRange.upperBound
            buffer.discard(before: max(0, end - Int64(retainedTail)))
        }

        let snapshot = buffer.snapshot()
        #expect(snapshot.totalAppendedSamples == 57_600_000)
        #expect(snapshot.retainedSamples == retainedTail)
        #expect(snapshot.peakRetainedSamples <= retainedTail + sampleRate)
        #expect(snapshot.blockCount <= 10)
        #expect(snapshot.peakBlockCount <= 14)
        #expect(snapshot.blockSlotCapacity == 60)
        #expect(!snapshot.isSealed)
    }

    @Test func segmentedPCMBufferSealsInsteadOfDroppingUnconfirmedAudio() throws {
        let buffer = SegmentedPCMBuffer(maximumRetainedSamples: 10, blockSize: 4)
        _ = try buffer.append(Array(0..<8).map(Float.init))

        do {
            _ = try buffer.append([8, 9, 10])
            Issue.record("Expected retention capacity to fail explicitly")
        } catch SegmentedPCMBuffer.BufferError.capacityExceeded(
            let maximum,
            let retained,
            let incoming
        ) {
            #expect(maximum == 10)
            #expect(retained == 8)
            #expect(incoming == 3)
        }

        let snapshot = buffer.snapshot()
        #expect(snapshot.retainedRange == 0..<8)
        #expect(snapshot.retainedSamples == 8)
        #expect(snapshot.totalAppendedSamples == 8)
        #expect(snapshot.isSealed)

        do {
            _ = try buffer.append([8])
            Issue.record("A discontinuous buffer must remain sealed")
        } catch SegmentedPCMBuffer.BufferError.capacityExceeded {
        }
    }

    @Test func segmentedPCMBufferTrimsAndReadsAcrossBlockAndRingBoundaries() throws {
        let buffer = SegmentedPCMBuffer(maximumRetainedSamples: 16, blockSize: 4)
        _ = try buffer.append(Array(0..<12).map(Float.init))
        buffer.discard(before: 5)

        let first = try #require(try buffer.window(from: 5, through: 12, maximumSamples: 16))
        #expect(first.range == 5..<12)
        #expect(first.samples == Array(5..<12).map(Float.init))

        buffer.discard(before: 8)
        _ = try buffer.append(Array(12..<20).map(Float.init))
        buffer.discard(before: 11)
        _ = try buffer.append(Array(20..<24).map(Float.init))

        let wrapped = try #require(try buffer.window(from: 11, through: 24, maximumSamples: 16))
        #expect(wrapped.range == 11..<24)
        #expect(wrapped.samples == Array(11..<24).map(Float.init))

        let snapshot = buffer.snapshot()
        #expect(snapshot.retainedRange == 11..<24)
        #expect(snapshot.retainedSamples == 13)
        #expect(snapshot.totalDiscardedSamples == 11)
        #expect(snapshot.blockCount <= snapshot.blockSlotCapacity)
    }

    @Test func agreementResultContainsOnlyUncommittedHypothesisTail() {
        let engine = WordAgreementEngine()
        let words = [
            TimedWord(text: "one", startTime: 0.0, endTime: 0.2),
            TimedWord(text: "two", startTime: 0.2, endTime: 0.4),
            TimedWord(text: "three", startTime: 0.4, endTime: 0.6),
            TimedWord(text: "four", startTime: 0.6, endTime: 0.8),
            TimedWord(text: "five.", startTime: 0.8, endTime: 1.0),
            TimedWord(text: "six", startTime: 1.0, endTime: 1.2),
            TimedWord(text: "seven.", startTime: 1.2, endTime: 1.4),
            TimedWord(text: "eight", startTime: 1.4, endTime: 1.6),
            TimedWord(text: "nine.", startTime: 1.6, endTime: 1.8)
        ]

        _ = engine.processTranscriptionResult(words: words)
        _ = engine.processTranscriptionResult(words: words)
        _ = engine.processTranscriptionResult(words: words)
        let confirmed = engine.processTranscriptionResult(words: words)

        #expect(confirmed.newlyConfirmedText == "one two three four five.")
        #expect(confirmed.hypothesisText == "six seven. eight nine.")
        #expect(!confirmed.hypothesisText.contains("one"))
    }

    @Test func oneHourRunOnSpeechKeepsAgreementHypothesisBoundedWithoutPunctuation() {
        var config = AgreementConfig()
        config.tokenConfirmationsNeeded = 1
        config.minWordsToConfirm = 1
        config.minWordConfidence = 0
        config.maximumUnconfirmedDurationSeconds = 9
        config.forcedConfirmationOverlapSeconds = 3
        let engine = WordAgreementEngine(config: config)
        var maximumUnconfirmedDuration = 0.0
        var committedWords = 0

        for second in 1...3_600 {
            let firstWord = Int(engine.confirmedEndTime)
            let words = (firstWord..<second).map { index in
                TimedWord(
                    text: "word\(index)",
                    startTime: Double(index),
                    endTime: Double(index + 1),
                    confidence: 1
                )
            }
            let result = engine.processTranscriptionResult(words: words)
            if !result.newlyConfirmedText.isEmpty {
                committedWords += result.newlyConfirmedText.split(separator: " ").count
            }
            maximumUnconfirmedDuration = max(
                maximumUnconfirmedDuration,
                Double(second) - engine.confirmedEndTime
            )
        }

        #expect(committedWords > 3_500)
        #expect(engine.confirmedEndTime > 3_590)
        #expect(maximumUnconfirmedDuration <= 9)
    }

    @Test func providerCapacityFailureIsExplicitAndPreservesRetainedPCM() async throws {
        var config = AgreementConfig()
        config.transcribeIntervalSeconds = 60
        let provider = FluidAudioStreamingProvider(
            config: config,
            maximumASRWindowSamples: 8_000,
            pcmBlockSize: 1_024,
            testingTranscriber: { samples in
                ASRResult(
                    text: "unused",
                    confidence: 1,
                    duration: Double(samples.count) / 16_000,
                    processingTime: 0.001
                )
            }
        )
        var events = provider.transcriptionEvents.makeAsyncIterator()
        try await provider.connect(model: fluidAudioTestModel(), language: "en")
        guard case .sessionStarted? = await events.next() else {
            Issue.record("Expected session start")
            return
        }

        try await provider.sendAudioChunk(Data(count: 6_000 * 2))
        do {
            try await provider.sendAudioChunk(Data(count: 3_000 * 2))
            Issue.record("Expected an explicit realtime window failure")
        } catch StreamingTranscriptionError.transcriptionWindowExceeded(let duration) {
            #expect(duration == 0.5)
        }

        guard case .error(let error)? = await events.next() else {
            Issue.record("Expected a provider error event")
            return
        }
        guard case .transcriptionWindowExceeded = error as? StreamingTranscriptionError else {
            Issue.record("Expected transcriptionWindowExceeded, got \(error)")
            return
        }
        let snapshot = provider.pcmBufferSnapshot
        #expect(snapshot.retainedSamples == 6_000)
        #expect(snapshot.totalAppendedSamples == 6_000)
        #expect(snapshot.isSealed)
        await provider.disconnect()
    }

    @Test func providerCommitTranscribesBoundedTailThenFinalizes() async throws {
        let recorder = FluidAudioTestTranscriberRecorder(resultText: "final tail")
        var config = AgreementConfig()
        config.transcribeIntervalSeconds = 60
        let provider = FluidAudioStreamingProvider(
            config: config,
            maximumASRWindowSamples: 24_000,
            pcmBlockSize: 1_024,
            testingTranscriber: { samples in
                recorder.transcribe(samples)
            }
        )
        var events = provider.transcriptionEvents.makeAsyncIterator()
        try await provider.connect(model: fluidAudioTestModel(), language: "en")
        guard case .sessionStarted? = await events.next() else {
            Issue.record("Expected session start")
            return
        }

        try await provider.sendAudioChunk(Data(count: 6_000 * 2))
        try await provider.commit()

        guard case .committed(let text)? = await events.next() else {
            Issue.record("Expected committed final tail")
            return
        }
        #expect(text == TextNormalizer.shared.normalizeSentence("final tail"))
        guard case .finalized? = await events.next() else {
            Issue.record("Expected finalized acknowledgement")
            return
        }
        #expect(recorder.callCount == 1)
        #expect(recorder.maximumInputSamples == 22_000)
        #expect(recorder.maximumInputSamples <= 24_000)
        await provider.disconnect()
    }

    @Test func fluidAudioProviderSourceHasNoFrontArrayRemoval() throws {
        let source = try String(
            contentsOf: projectRoot()
                .appendingPathComponent("VoiceInk/Transcription/Streaming/FluidAudioStreamingProvider.swift"),
            encoding: .utf8
        )
        let bufferSource = try String(
            contentsOf: projectRoot()
                .appendingPathComponent("VoiceInk/Transcription/Streaming/SegmentedPCMBuffer.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("removeFirst"))
        #expect(!bufferSource.contains("removeFirst"))
    }
}

private final class FluidAudioTestTranscriberRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let resultText: String
    private var _callCount = 0
    private var _maximumInputSamples = 0

    init(resultText: String) {
        self.resultText = resultText
    }

    var callCount: Int {
        lock.withLock { _callCount }
    }

    var maximumInputSamples: Int {
        lock.withLock { _maximumInputSamples }
    }

    func transcribe(_ samples: [Float]) -> ASRResult {
        lock.withLock {
            _callCount += 1
            _maximumInputSamples = max(_maximumInputSamples, samples.count)
        }
        return ASRResult(
            text: resultText,
            confidence: 1,
            duration: Double(samples.count) / 16_000,
            processingTime: 0.001
        )
    }
}

private func fluidAudioTestModel() -> CloudModel {
    CloudModel(
        name: "parakeet-tdt-0.6b-v3",
        displayName: "FluidAudio test",
        description: "Long-duration streaming test model",
        provider: .fluidAudio,
        speed: 1,
        accuracy: 1,
        isMultilingual: true,
        supportsStreaming: true,
        supportedLanguages: ["en": "English"]
    )
}

private func projectRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
