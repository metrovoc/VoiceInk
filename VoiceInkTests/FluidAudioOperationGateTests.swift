import Foundation
import Testing
@testable import VoiceInk_CE

struct FluidAudioOperationGateTests {
    @Test func suspendedOperationsNeverReenterSharedRuntime() async {
        let gate = FluidAudioExclusiveOperationGate()
        let observation = FluidAudioGateObservation()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    await gate.run {
                        observation.enter()
                        try? await Task.sleep(nanoseconds: 250_000)
                        observation.leave()
                    }
                }
            }
        }

        #expect(observation.completedCount == 64)
        #expect(observation.maximumConcurrentCount == 1)
    }

    @Test func whisperInferenceGateOwnsTheWholeSuspendedOperation() async {
        let gate = WhisperTranscriptionOperationGate()
        let observation = FluidAudioGateObservation()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    await gate.run {
                        observation.enter()
                        try? await Task.sleep(nanoseconds: 250_000)
                        observation.leave()
                    }
                }
            }
        }

        #expect(observation.completedCount == 64)
        #expect(observation.maximumConcurrentCount == 1)
    }
}

private final class FluidAudioGateObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var concurrentCount = 0
    private var _maximumConcurrentCount = 0
    private var _completedCount = 0

    var maximumConcurrentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _maximumConcurrentCount
    }

    var completedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _completedCount
    }

    func enter() {
        lock.lock()
        concurrentCount += 1
        _maximumConcurrentCount = max(_maximumConcurrentCount, concurrentCount)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        concurrentCount -= 1
        _completedCount += 1
        lock.unlock()
    }
}
