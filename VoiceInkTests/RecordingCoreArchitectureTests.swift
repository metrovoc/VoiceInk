import Foundation
import Testing
@testable import VoiceInk_CE

private final class LockedContextTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    private var strings: [String: String?] = [:]

    func increment(_ key: String) {
        lock.lock()
        values[key, default: 0] += 1
        lock.unlock()
    }

    func count(_ key: String) -> Int {
        lock.lock()
        let value = values[key, default: 0]
        lock.unlock()
        return value
    }

    func set(_ value: String?, for key: String) {
        lock.lock()
        strings[key] = value
        lock.unlock()
    }

    func string(_ key: String) -> String? {
        lock.lock()
        let value = strings[key] ?? nil
        lock.unlock()
        return value
    }
}

@Suite(.serialized)
struct RecordingCoreArchitectureTests {
    @Test func startupAudioRelayOverwritesOldestChunkInConstantTimeRingOrder() {
        let relay = StartupAudioChunkRelay(maxBufferedChunks: 3)
        for value in UInt8(1)...5 {
            relay.send(Data([value]))
        }

        let drainedValues = LockedCoreByteCollector()
        let stats = relay.attach { data in
            if let value = data.first {
                drainedValues.append(value)
            }
        }

        #expect(drainedValues.values == [3, 4, 5])
        #expect(stats.bufferedChunks == 3)
        #expect(stats.bufferedBytes == 3)
        #expect(stats.droppedChunks == 2)
        #expect(stats.droppedBytes == 2)
    }

    @Test func startupAudioRelayPreservesChunksSentWhileAttachIsDraining() {
        let relay = StartupAudioChunkRelay(maxBufferedChunks: 4)
        relay.send(Data([1]))
        relay.send(Data([2]))

        let drainedValues = LockedCoreByteCollector()
        _ = relay.attach { data in
            guard let value = data.first else { return }
            drainedValues.append(value)
            if value == 1 {
                relay.send(Data([3]))
            }
        }

        #expect(drainedValues.values == [1, 2, 3])
        let postAttachStats = relay.discard()
        #expect(postAttachStats.bufferedChunks == 0)
        #expect(postAttachStats.droppedChunks == 0)
    }

    @Test func startupAudioRelayReportsOverflowThatOccursDuringDrain() async {
        let relay = StartupAudioChunkRelay(maxBufferedChunks: 4)
        relay.send(Data([0]))
        let callbackStarted = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)

        let drainedValues = LockedCoreByteCollector()
        let attachTask = Task.detached {
            let stats = relay.attach { data in
                guard let value = data.first else { return }
                drainedValues.append(value)
                if value == 0 {
                    callbackStarted.signal()
                    releaseCallback.wait()
                }
            }
            return stats
        }

        #expect(RecordingBlockingWait.wait(callbackStarted, timeout: .now() + 1) == .success)
        for value in UInt8(1)...10 {
            relay.send(Data([value]))
        }
        releaseCallback.signal()

        let stats = await attachTask.value
        #expect(drainedValues.values == [0, 7, 8, 9, 10])
        #expect(stats.bufferedChunks == 5)
        #expect(stats.bufferedBytes == 5)
        #expect(stats.droppedChunks == 6)
        #expect(stats.droppedBytes == 6)
    }

    @MainActor
    @Test func startupRelayBacklogDrainNeverOccupiesMainActor() async {
        let relay = StartupAudioChunkRelay(maxBufferedChunks: 200)
        for value in 0..<100 {
            relay.send(Data([UInt8(value)]))
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let drainTask = Task { @MainActor in
            await StartupAudioRelayDrainer.attach(relay) { _ in
                Thread.sleep(forTimeInterval: 0.001)
            }
        }

        // Give the MainActor drain task a chance to begin. Its detached worker
        // should make the actor available again immediately, not after 100 ms
        // of callback work.
        await Task.yield()
        let mainActorDelay = ProcessInfo.processInfo.systemUptime - startedAt
        #expect(mainActorDelay < 0.050)

        let stats = await drainTask.value
        #expect(stats.bufferedChunks == 100)
        #expect(ProcessInfo.processInfo.systemUptime - startedAt >= 0.090)
    }

    @Test func modeSettleBudgetReturnsWithoutJoiningUncooperativeTask() async {
        let unresolvedTask = Task.detached {
            _ = try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let startedAt = ProcessInfo.processInfo.systemUptime

        let settled = await RecordingModeSettleBudget.wait(
            for: unresolvedTask,
            nanoseconds: 5_000_000
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        #expect(!settled)
        #expect(elapsed < 0.100)
        await unresolvedTask.value
    }

    @MainActor
    @Test func disabledEnhancementProducesAZeroWorkPlanEvenWhenContextFlagsAreStale() {
        let configuration = EnhancementRuntimeConfiguration(
            mode: nil,
            isEnabled: false,
            prompt: nil,
            provider: nil,
            modelName: nil,
            useClipboardContext: true,
            useSelectedTextContext: true,
            useScreenCaptureContext: true
        )

        let plan = RecordingContextCapturePlan(configuration: configuration)

        #expect(plan == .none)
        #expect(RecordingContextCaptureService.startCapture(plan: plan) == nil)
    }

    @MainActor
    @Test func emptyContextPlanCreatesNoTasksOrCaptureOwner() {
        let plan = RecordingContextCapturePlan(
            capturesClipboard: false,
            capturesSelectedText: false,
            capturesScreen: false
        )

        #expect(plan.isEmpty)
        #expect(RecordingContextCaptureService.startCapture(plan: plan) == nil)
    }

    @MainActor
    @Test func modeWithoutAIEnhancementNeverCapturesDefaultSelectedText() {
        let mode = ModeConfig(
            name: "Plain dictation",
            isAIEnhancementEnabled: false,
            useClipboardContext: true,
            useSelectedTextContext: true,
            useScreenCapture: true
        )

        let plan = RecordingContextCapturePlan(mode: mode)

        #expect(plan == .none)
        #expect(RecordingContextCaptureService.startCapture(plan: plan) == nil)
    }

    @MainActor
    @Test func synchronousContextSideLaneWorkNeverBlocksMainControlPath() async {
        let state = LockedContextTestState()
        let releaseSideLane = DispatchSemaphore(value: 0)
        let (started, startedContinuation) = AsyncStream.makeStream(of: String.self)
        let plan = RecordingContextCapturePlan(
            capturesClipboard: true,
            capturesSelectedText: true,
            capturesScreen: true
        )
        let triggerSnapshot = RecordingContextTriggerSnapshot(
            clipboardText: "trigger clipboard",
            capturingProcessID: 999,
            target: RecordingContextTarget(
                processID: 1000,
                bundleIdentifier: "test.target",
                applicationName: "Target"
            ),
            windowHint: RecordingContextWindowHint(
                processID: 1000,
                title: "Frozen Window",
                frame: nil
            )
        )

        let constructionStartedAt = ProcessInfo.processInfo.systemUptime
        let capture = RecordingContextCapture(
            plan: plan,
            triggerSnapshot: triggerSnapshot,
            selectedText: { triggerSnapshot in
                state.set(triggerSnapshot.clipboardText, for: "selected-observed-clipboard")
                startedContinuation.yield("selectedText")
                _ = RecordingBlockingWait.wait(releaseSideLane, timeout: .now() + 1)
                return "selection"
            },
            screenText: { triggerSnapshot in
                state.set(triggerSnapshot.windowHint?.title, for: "screen-observed-window")
                startedContinuation.yield("screen")
                _ = RecordingBlockingWait.wait(releaseSideLane, timeout: .now() + 1)
                return "screen"
            }
        )
        let constructionElapsed = ProcessInfo.processInfo.systemUptime - constructionStartedAt

        // Clipboard is complete before either pasteboard-mutating side-lane
        // operation can begin. The two synchronous waits run off MainActor.
        #expect(capture.taskCount == 2)
        #expect(capture.snapshot.clipboardText == "trigger clipboard")
        #expect(constructionElapsed < 0.050)

        var startedIterator = started.makeAsyncIterator()
        let first = await startedIterator.next()
        let second = await startedIterator.next()
        #expect(Set([first, second].compactMap { $0 }) == ["selectedText", "screen"])

        var mainControlPathRan = false
        let mainControlMarker = Task { @MainActor in
            mainControlPathRan = true
        }
        await mainControlMarker.value
        #expect(mainControlPathRan)
        #expect(state.string("selected-observed-clipboard") == "trigger clipboard")
        #expect(state.string("screen-observed-window") == "Frozen Window")

        releaseSideLane.signal()
        releaseSideLane.signal()
        startedContinuation.finish()
        capture.cancel()
    }

    @MainActor
    @Test func contextReconciliationCancelsAndErasesCapabilitiesNoLongerRequested() async {
        let state = LockedContextTestState()
        let initialPlan = RecordingContextCapturePlan(
            capturesClipboard: true,
            capturesSelectedText: true,
            capturesScreen: false
        )
        let finalPlan = RecordingContextCapturePlan(
            capturesClipboard: false,
            capturesSelectedText: true,
            capturesScreen: true
        )
        let capture = RecordingContextCapture(
            plan: initialPlan,
            triggerSnapshot: RecordingContextTriggerSnapshot(
                clipboardText: "trigger clipboard",
                target: nil,
                windowHint: nil
            ),
            selectedText: { _ in
                state.increment("selected")
                return "trigger selection"
            },
            screenText: { _ in
                state.increment("screen")
                return "final screen"
            }
        )

        let initialSnapshot = await capture.snapshotAwaitingReadiness(timeoutNanoseconds: 100_000_000)
        #expect(initialSnapshot.clipboardText == "trigger clipboard")
        #expect(initialSnapshot.selectedText == "trigger selection")

        capture.reconcile(to: finalPlan)
        let finalSnapshot = await capture.snapshotAwaitingReadiness(timeoutNanoseconds: 100_000_000)

        #expect(capture.taskCount == 2)
        #expect(finalSnapshot.clipboardText == nil)
        #expect(finalSnapshot.selectedText == "trigger selection")
        #expect(finalSnapshot.screenText == "final screen")
        #expect(state.count("selected") == 1)
        #expect(state.count("screen") == 1)
    }

    @MainActor
    @Test func shortRecordingAwaitsAlreadyRequestedContextBeforeEnhancement() async {
        let (releaseSelection, releaseSelectionContinuation) = AsyncStream.makeStream(of: Void.self)
        let (selectionStarted, selectionStartedContinuation) = AsyncStream.makeStream(of: Void.self)
        let capture = RecordingContextCapture(
            plan: RecordingContextCapturePlan(
                capturesClipboard: false,
                capturesSelectedText: true,
                capturesScreen: false
            ),
            triggerSnapshot: RecordingContextTriggerSnapshot(
                clipboardText: "frozen clipboard",
                target: nil,
                windowHint: nil
            ),
            selectedText: { _ in
                selectionStartedContinuation.yield()
                var iterator = releaseSelection.makeAsyncIterator()
                _ = await iterator.next()
                return "ready selection"
            },
            screenText: { _ in nil }
        )

        var startedIterator = selectionStarted.makeAsyncIterator()
        _ = await startedIterator.next()
        let readiness = Task { @MainActor in
            await capture.snapshotAwaitingReadiness(timeoutNanoseconds: 500_000_000)
        }

        try? await Task.sleep(nanoseconds: 15_000_000)
        releaseSelectionContinuation.yield()
        releaseSelectionContinuation.finish()
        selectionStartedContinuation.finish()

        let snapshot = await readiness.value
        #expect(snapshot.selectedText == "ready selection")
    }

    @MainActor
    @Test func contextReadinessTimeoutIsAHardBoundForUncooperativeCapture() async {
        let releaseSelection = DispatchSemaphore(value: 0)
        let (selectionStarted, selectionStartedContinuation) = AsyncStream.makeStream(of: Void.self)
        let capture = RecordingContextCapture(
            plan: RecordingContextCapturePlan(
                capturesClipboard: true,
                capturesSelectedText: true,
                capturesScreen: false
            ),
            triggerSnapshot: RecordingContextTriggerSnapshot(
                clipboardText: "available immediately",
                target: nil,
                windowHint: nil
            ),
            selectedText: { _ in
                selectionStartedContinuation.yield()
                _ = RecordingBlockingWait.wait(releaseSelection, timeout: .now() + 1)
                return "too late"
            },
            screenText: { _ in nil }
        )

        var startedIterator = selectionStarted.makeAsyncIterator()
        _ = await startedIterator.next()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let snapshot = await capture.snapshotAwaitingReadiness(timeoutNanoseconds: 10_000_000)
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        #expect(snapshot.clipboardText == "available immediately")
        #expect(snapshot.selectedText == nil)
        #expect(elapsed < 0.100)

        releaseSelection.signal()
        selectionStartedContinuation.finish()
        capture.cancel()
    }

    @MainActor
    @Test func preconnectCanStartWhileHardwareStartIsStillPending() async throws {
        let configuration = TranscriptionRuntimeConfiguration(
            mode: nil,
            model: CloudModel(
                name: "architecture-realtime",
                displayName: "Architecture Realtime",
                description: "Test model",
                provider: .deepgram,
                speed: 1,
                accuracy: 1,
                isMultilingual: true,
                supportsStreaming: true,
                supportedLanguages: ["en": "English"]
            ),
            language: "en",
            isRealtimeEnabled: true
        )
        let (hardwareRelease, hardwareReleaseContinuation) = AsyncStream.makeStream(of: Void.self)
        let (preconnectStarted, preconnectStartedContinuation) = AsyncStream.makeStream(of: Void.self)
        var hardwareCompleted = false

        let hardwareStart = Task { @MainActor in
            var iterator = hardwareRelease.makeAsyncIterator()
            _ = await iterator.next()
            hardwareCompleted = true
        }
        let preconnect = RecordingRealtimePreconnectLifecycle.begin(
            configuration: configuration,
            startupStartedAt: ProcessInfo.processInfo.systemUptime,
            prepare: {
                preconnectStartedContinuation.yield()
                return nil
            }
        )

        var preconnectIterator = preconnectStarted.makeAsyncIterator()
        _ = await preconnectIterator.next()
        #expect(!hardwareCompleted)

        hardwareReleaseContinuation.yield()
        hardwareReleaseContinuation.finish()
        preconnectStartedContinuation.finish()
        await hardwareStart.value
        _ = try await preconnect.task.value
    }

    @MainActor
    @Test func finalizationGateRunsExactlyOneOperationForConcurrentCallers() async {
        let gate = RecordingFinalizationGate()
        let recordingID = UUID()
        var operationCount = 0
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let (release, releaseContinuation) = AsyncStream.makeStream(of: Void.self)

        let first = Task { @MainActor in
            await gate.run(recordingID: recordingID) {
                operationCount += 1
                startedContinuation.yield()
                var iterator = release.makeAsyncIterator()
                _ = await iterator.next()
            }
        }

        var startedIterator = started.makeAsyncIterator()
        _ = await startedIterator.next()
        startedContinuation.finish()

        let second = Task { @MainActor in
            await gate.run(recordingID: recordingID) {
                operationCount += 1
            }
        }

        await Task.yield()
        #expect(operationCount == 1)
        releaseContinuation.yield()
        releaseContinuation.finish()
        await first.value
        await second.value

        #expect(operationCount == 1)
        #expect(!gate.isFinalizing)
    }

    @MainActor
    @Test func finalizationGateDoesNotLetOldPipelineBlockNewRecording() async {
        let gate = RecordingFinalizationGate()
        let oldRecordingID = UUID()
        let newRecordingID = UUID()
        let (oldStarted, oldStartedContinuation) = AsyncStream.makeStream(of: Void.self)
        let (releaseOld, releaseOldContinuation) = AsyncStream.makeStream(of: Void.self)

        let oldFinalization = Task { @MainActor in
            await gate.run(recordingID: oldRecordingID) {
                oldStartedContinuation.yield()
                var iterator = releaseOld.makeAsyncIterator()
                _ = await iterator.next()
            }
        }

        var oldStartedIterator = oldStarted.makeAsyncIterator()
        _ = await oldStartedIterator.next()
        oldStartedContinuation.finish()

        var newFinalizationRan = false
        await gate.run(recordingID: newRecordingID) {
            newFinalizationRan = true
        }

        #expect(newFinalizationRan)
        #expect(gate.isFinalizing)

        releaseOldContinuation.yield()
        releaseOldContinuation.finish()
        await oldFinalization.value
        #expect(!gate.isFinalizing)
    }

    @MainActor
    @Test func resumedOldFinalizerKeepsItsSnapshotAndCannotClearNewGeneration() async {
        let oldRecordingID = UUID()
        let newRecordingID = UUID()
        let oldURL = URL(fileURLWithPath: "/tmp/old-generation.wav")
        let newURL = URL(fileURLWithPath: "/tmp/new-generation.wav")
        var activeRecordingID: UUID? = oldRecordingID
        var activeAudioURL: URL? = oldURL
        var meterValue = 0.75
        var didScheduleWarmUp = false
        let (oldStopped, oldStoppedContinuation) = AsyncStream.makeStream(of: Void.self)
        let (resumeOldStop, resumeOldStopContinuation) = AsyncStream.makeStream(of: Void.self)

        let oldFinalizer = Task { @MainActor in
            // VoiceInkEngine captures this immutable resource set before the
            // hardware-stop suspension point.
            let capturedAudioURL = activeAudioURL
            oldStoppedContinuation.yield()
            var resumeIterator = resumeOldStop.makeAsyncIterator()
            _ = await resumeIterator.next()

            if RecordingGenerationOwnershipPolicy.owns(
                activeRecordingID: activeRecordingID,
                generationID: oldRecordingID
            ) {
                activeAudioURL = nil
                meterValue = -160
                didScheduleWarmUp = true
            }
            return capturedAudioURL
        }

        var stoppedIterator = oldStopped.makeAsyncIterator()
        _ = await stoppedIterator.next()

        // Cancel old work, install a complete new generation, then allow the
        // old hardware stop to resume.
        activeRecordingID = newRecordingID
        activeAudioURL = newURL
        resumeOldStopContinuation.yield()
        resumeOldStopContinuation.finish()
        oldStoppedContinuation.finish()

        let consumedAudioURL = await oldFinalizer.value
        #expect(consumedAudioURL == oldURL)
        #expect(activeRecordingID == newRecordingID)
        #expect(activeAudioURL == newURL)
        #expect(meterValue == 0.75)
        #expect(!didScheduleWarmUp)
    }

    @Test func concurrentStopRequestsJoinOnePhysicalGenerationDrain() async {
        let coordinator = RecordingHardwareStopCoordinator()
        let generationID = UUID()
        coordinator.activate(generationID: generationID)
        let observation = HardwareStopObservation()

        let handles = await withTaskGroup(
            of: RecordingHardwareStopHandle.self,
            returning: [RecordingHardwareStopHandle].self
        ) { group in
            for _ in 0..<32 {
                group.addTask {
                    coordinator.request(generationID: generationID) { streamingDrained, completion in
                        observation.recordEnqueue(
                            streamingDrained: streamingDrained,
                            completion: completion
                        )
                    }
                }
            }

            var handles: [RecordingHardwareStopHandle] = []
            for await handle in group {
                handles.append(handle)
            }
            return handles
        }

        #expect(observation.enqueueCount == 1)
        observation.completeStreamingPhase()
        for handle in handles {
            await handle.streamingValue()
        }
        #expect(observation.completedStreamingPhases == 1)
        #expect(observation.completedStopPhases == 0)
        observation.completeLatest()
        for handle in handles {
            await handle.value()
        }

        // A stop request that arrives after completion still joins the retained
        // generation handle instead of enqueuing a second AUHAL drain.
        let lateHandle = coordinator.request(generationID: generationID) { streamingDrained, completion in
            observation.recordEnqueue(
                streamingDrained: streamingDrained,
                completion: completion
            )
        }
        await lateHandle.streamingValue()
        await lateHandle.value()
        #expect(observation.enqueueCount == 1)

        let newGenerationID = UUID()
        coordinator.activate(generationID: newGenerationID)
        let newHandle = coordinator.request(generationID: newGenerationID) { streamingDrained, completion in
            observation.recordEnqueue(
                streamingDrained: streamingDrained,
                completion: completion
            )
        }
        let staleHandle = coordinator.request(generationID: generationID) { streamingDrained, completion in
            observation.recordEnqueue(
                streamingDrained: streamingDrained,
                completion: completion
            )
        }
        await staleHandle.streamingValue()
        await staleHandle.value()
        #expect(observation.enqueueCount == 2)
        observation.completeStreamingPhase()
        await newHandle.streamingValue()
        observation.completeLatest()
        await newHandle.value()
    }

    @Test func providerFinalizationIsRequestedBeforePendingPersistenceStarts() throws {
        let source = try projectSource("VoiceInk/Transcription/Engine/VoiceInkEngine.swift")
        let finalizationBody = try #require(
            source.components(
                separatedBy: "private func performActiveRecordingFinalization("
            ).last?
                .components(separatedBy: "// MARK: - Cancellation").first
        )
        let streamingBarrier = try #require(
            finalizationBody.range(of: "await hardwareStop.streamingValue()")
        )
        let providerFinalization = try #require(
            finalizationBody.range(of: "snapshot.session?.requestFinalization")
        )
        let pendingPersistence = try #require(
            finalizationBody.range(
                of: "RecordingPersistenceCoordinator.beginPersistingPending"
            )
        )

        #expect(streamingBarrier.lowerBound < providerFinalization.lowerBound)
        #expect(providerFinalization.lowerBound < pendingPersistence.lowerBound)
    }

    @Test func realtimeFluidCaptureNeverStartsACompetingBatchRuntime() {
        #expect(
            !RecordingSideLaneModelLoadPolicy.shouldLoadFluidBatchRuntime(
                provider: .fluidAudio,
                isRealtimeEnabled: true
            )
        )
        #expect(
            RecordingSideLaneModelLoadPolicy.shouldLoadFluidBatchRuntime(
                provider: .fluidAudio,
                isRealtimeEnabled: false
            )
        )
        #expect(
            !RecordingSideLaneModelLoadPolicy.shouldLoadFluidBatchRuntime(
                provider: .whisper,
                isRealtimeEnabled: false
            )
        )
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

private final class LockedCoreByteCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt8] = []

    var values: [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: UInt8) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class HardwareStopObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var _enqueueCount = 0
    private var _completedStreamingPhases = 0
    private var _completedStopPhases = 0
    private var streamingDrained: (@Sendable () -> Void)?
    private var completion: (@Sendable () -> Void)?

    var enqueueCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _enqueueCount
    }

    var completedStreamingPhases: Int {
        lock.lock()
        defer { lock.unlock() }
        return _completedStreamingPhases
    }

    var completedStopPhases: Int {
        lock.lock()
        defer { lock.unlock() }
        return _completedStopPhases
    }

    func recordEnqueue(
        streamingDrained: @escaping @Sendable () -> Void,
        completion: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        _enqueueCount += 1
        self.streamingDrained = { [weak self] in
            self?.recordStreamingCompletion()
            streamingDrained()
        }
        self.completion = { [weak self] in
            self?.recordStopCompletion()
            completion()
        }
        lock.unlock()
    }

    func completeStreamingPhase() {
        lock.lock()
        let streamingDrained = streamingDrained
        self.streamingDrained = nil
        lock.unlock()
        streamingDrained?()
    }

    func completeLatest() {
        lock.lock()
        let completion = completion
        self.completion = nil
        lock.unlock()
        completion?()
    }

    private func recordStreamingCompletion() {
        lock.lock()
        _completedStreamingPhases += 1
        lock.unlock()
    }

    private func recordStopCompletion() {
        lock.lock()
        _completedStopPhases += 1
        lock.unlock()
    }
}

/// Some regression tests deliberately model cancellation-ignoring synchronous
/// system APIs. Keep that blocking primitive inside a synchronous helper so
/// the async test body itself remains Swift 6-correct.
private enum RecordingBlockingWait {
    static func wait(
        _ semaphore: DispatchSemaphore,
        timeout: DispatchTime
    ) -> DispatchTimeoutResult {
        semaphore.wait(timeout: timeout)
    }
}
