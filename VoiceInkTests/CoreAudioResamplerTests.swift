import Foundation
import Testing
@testable import VoiceInk_CE

@Suite(.serialized)
struct CoreAudioResamplerTests {
    @Test(arguments: [48_000.0, 44_100.0])
    func randomCallbackSizesKeepLongRunSampleCountWithinOneFrame(
        inputSampleRate: Double
    ) {
        let outputSampleRate = 16_000.0
        let totalInputFrames = Int(inputSampleRate * 120)
        var resampler = StatefulLinearPCMResampler()
        resampler.reset(
            inputSampleRate: inputSampleRate,
            outputSampleRate: outputSampleRate
        )

        let maximumFrames = 4_096
        let input = UnsafeMutablePointer<Float32>.allocate(capacity: maximumFrames)
        let output = UnsafeMutablePointer<Int16>.allocate(capacity: maximumFrames + 2)
        defer {
            input.deallocate()
            output.deallocate()
        }
        input.initialize(repeating: 0, count: maximumFrames)

        var generator = DeterministicResamplerGenerator(seed: 0xA17D_10C5)
        var remaining = totalInputFrames
        var totalOutputFrames = 0
        while remaining > 0 {
            let requested = 1 + Int(generator.next() % UInt64(maximumFrames))
            let frameCount = min(requested, remaining)
            let produced = resampler.process(
                inputSamples: UnsafePointer(input),
                frameCount: frameCount,
                channelCount: 1,
                outputBuffer: output,
                outputCapacity: maximumFrames + 2
            )
            #expect(produced >= 0)
            totalOutputFrames += max(0, produced)
            remaining -= frameCount
        }

        let idealOutputFrames = Int(
            (Double(totalInputFrames) * outputSampleRate / inputSampleRate).rounded()
        )
        #expect(abs(totalOutputFrames - idealOutputFrames) <= 1)
    }

    @Test func randomBoundariesMatchOneContinuousBuffer() {
        let inputSampleRate = 44_100.0
        let outputSampleRate = 16_000.0
        let frameCount = 32_771
        let input = (0..<frameCount).map { index in
            Float32(sin(Double(index) * 0.017) * 0.8)
        }

        let continuous = resample(
            input,
            inputSampleRate: inputSampleRate,
            outputSampleRate: outputSampleRate,
            callbackSizes: [frameCount]
        )

        var generator = DeterministicResamplerGenerator(seed: 0xB0A1_DA7A)
        var callbackSizes: [Int] = []
        var remaining = frameCount
        while remaining > 0 {
            let size = min(1 + Int(generator.next() % 997), remaining)
            callbackSizes.append(size)
            remaining -= size
        }
        let chunked = resample(
            input,
            inputSampleRate: inputSampleRate,
            outputSampleRate: outputSampleRate,
            callbackSizes: callbackSizes
        )

        #expect(chunked == continuous)
    }

    @Test func sameSampleRatePreservesEveryFrameAndMixesChannels() {
        let interleavedStereo: [Float32] = [
            0.2, 0.6,
            -0.4, 0.2,
            1.0, 1.0,
            -1.0, -1.0,
        ]
        var resampler = StatefulLinearPCMResampler()
        resampler.reset(inputSampleRate: 16_000, outputSampleRate: 16_000)
        var output = [Int16](repeating: 0, count: 4)

        let produced = interleavedStereo.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                resampler.process(
                    inputSamples: inputBuffer.baseAddress!,
                    frameCount: 4,
                    channelCount: 2,
                    outputBuffer: outputBuffer.baseAddress!,
                    outputCapacity: outputBuffer.count
                )
            }
        }

        #expect(produced == 4)
        #expect(output == [Int16(0.4 * 32767), Int16(-0.1 * 32767), 32767, -32767])
    }

    @Test func resetDiscardsPriorPhaseAndBoundarySample() {
        let first: [Float32] = [0.8, 0.7, 0.6, 0.5, 0.4]
        let second: [Float32] = [-0.7, -0.4, 0.1, 0.6, 0.9]
        var reused = StatefulLinearPCMResampler()
        reused.reset(inputSampleRate: 48_000, outputSampleRate: 16_000)
        _ = process(first, with: &reused)
        reused.reset(inputSampleRate: 48_000, outputSampleRate: 16_000)
        let afterReset = process(second, with: &reused)

        var fresh = StatefulLinearPCMResampler()
        fresh.reset(inputSampleRate: 48_000, outputSampleRate: 16_000)
        let fromFreshState = process(second, with: &fresh)
        #expect(afterReset == fromFreshState)
    }

    @Test func callbackConversionPathContainsNoLockAllocationOrExecutorHop() throws {
        let source = try projectSource("VoiceInk/CoreAudioRecorder.swift")
        let conversion = try #require(
            source.components(separatedBy: "private func convertAndEnqueuePCM").last?
                .components(separatedBy: "private func recordCaptureDrop").first
        )
        let resampler = try #require(
            source.components(separatedBy: "struct StatefulLinearPCMResampler").last?
                .components(separatedBy: "// MARK: - Core Audio Recorder").first
        )

        for realtimeSource in [conversion, resampler] {
            #expect(!realtimeSource.contains("lock()"))
            #expect(!realtimeSource.contains(".allocate("))
            #expect(!realtimeSource.contains("Data("))
            #expect(!realtimeSource.contains("Task"))
            #expect(!realtimeSource.contains("await"))
        }
    }

    private func resample(
        _ input: [Float32],
        inputSampleRate: Double,
        outputSampleRate: Double,
        callbackSizes: [Int]
    ) -> [Int16] {
        var resampler = StatefulLinearPCMResampler()
        resampler.reset(
            inputSampleRate: inputSampleRate,
            outputSampleRate: outputSampleRate
        )
        var result: [Int16] = []
        var offset = 0

        input.withUnsafeBufferPointer { inputBuffer in
            for callbackSize in callbackSizes {
                let capacity = callbackSize + 2
                let output = UnsafeMutablePointer<Int16>.allocate(capacity: capacity)
                defer { output.deallocate() }
                let produced = resampler.process(
                    inputSamples: inputBuffer.baseAddress!.advanced(by: offset),
                    frameCount: callbackSize,
                    channelCount: 1,
                    outputBuffer: output,
                    outputCapacity: capacity
                )
                #expect(produced >= 0)
                if produced > 0 {
                    result.append(contentsOf: UnsafeBufferPointer(start: output, count: produced))
                }
                offset += callbackSize
            }
        }
        #expect(offset == input.count)
        return result
    }

    private func process(
        _ input: [Float32],
        with resampler: inout StatefulLinearPCMResampler
    ) -> [Int16] {
        var output = [Int16](repeating: 0, count: input.count + 2)
        let produced = input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                resampler.process(
                    inputSamples: inputBuffer.baseAddress!,
                    frameCount: inputBuffer.count,
                    channelCount: 1,
                    outputBuffer: outputBuffer.baseAddress!,
                    outputCapacity: outputBuffer.count
                )
            }
        }
        return Array(output.prefix(max(0, produced)))
    }

    private func projectSource(_ relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

private struct DeterministicResamplerGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
