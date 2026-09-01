import Foundation
import SwiftUI
import SwiftData
import Testing
@testable import VoiceInk_CE

struct RecordingLifecycleRegressionTests {
    @Test func recordingShortcutPolicyRejectsOnlyNonInteractiveStates() {
        #expect(RecordingInteractionPolicy.canProcessRecordingShortcut(when: .idle))
        #expect(RecordingInteractionPolicy.canProcessRecordingShortcut(when: .starting))
        #expect(RecordingInteractionPolicy.canProcessRecordingShortcut(when: .recording))

        for state in [RecordingState.transcribing, .enhancing, .busy] {
            #expect(!RecordingInteractionPolicy.canProcessRecordingShortcut(when: state))
        }
    }

    @Test func recorderTogglePolicyNeverStopsDuringStartup() {
        #expect(RecordingInteractionPolicy.toggleAction(isRecorderVisible: false, state: .idle) == .start)
        #expect(RecordingInteractionPolicy.toggleAction(isRecorderVisible: true, state: .recording) == .stopRecording)
        #expect(RecordingInteractionPolicy.toggleAction(isRecorderVisible: true, state: .idle) == .cancelIdleRecorder)
        #expect(
            RecordingInteractionPolicy.toggleAction(
                isRecorderVisible: true,
                state: .idle,
                canSendAssistantFollowUp: true
            ) == .startAssistantFollowUp
        )

        #expect(RecordingInteractionPolicy.toggleAction(isRecorderVisible: false, state: .starting) == .stopRecording)
        #expect(RecordingInteractionPolicy.toggleAction(isRecorderVisible: true, state: .starting) == .stopRecording)

        for state in [RecordingState.transcribing, .enhancing, .busy] {
            #expect(RecordingInteractionPolicy.toggleAction(isRecorderVisible: false, state: state) == .ignore)
            #expect(RecordingInteractionPolicy.toggleAction(isRecorderVisible: true, state: state) == .ignore)
        }
    }

    @Test func recorderTogglePolicyDismissesOnlyPreCaptureStartupCancellation() {
        #expect(
            RecordingInteractionPolicy.shouldDismissPanelAfterStop(
                previousState: .starting,
                currentState: .idle,
                isRecorderVisible: true
            )
        )
        #expect(
            !RecordingInteractionPolicy.shouldDismissPanelAfterStop(
                previousState: .starting,
                currentState: .starting,
                isRecorderVisible: true
            )
        )
        #expect(
            !RecordingInteractionPolicy.shouldDismissPanelAfterStop(
                previousState: .recording,
                currentState: .idle,
                isRecorderVisible: true
            )
        )
        #expect(
            !RecordingInteractionPolicy.shouldDismissPanelAfterStop(
                previousState: .starting,
                currentState: .idle,
                isRecorderVisible: false
            )
        )
    }

    @Test func recordingControlPlaneStopPolicyDefersPipelineUntilSessionIsReady() {
        let activeStartID = UUID()

        #expect(
            RecordingControlPlaneStopPolicy.action(
                activeRecordingStartID: activeStartID,
                isControlPlaneReady: false
            ) == .stopRecorderAndWaitForControlPlane
        )
        #expect(
            RecordingControlPlaneStopPolicy.action(
                activeRecordingStartID: activeStartID,
                isControlPlaneReady: true
            ) == .finishImmediately
        )
        #expect(
            RecordingControlPlaneStopPolicy.action(
                activeRecordingStartID: nil,
                isControlPlaneReady: false
            ) == .finishImmediately
        )
    }

    @Test func recordingStartupContinuationPolicyDoesNotDependOnPanelVisibility() {
        let startID = UUID()

        #expect(
            RecordingStartupContinuationPolicy.shouldContinue(
                activeRecordingStartID: startID,
                startID: startID,
                shouldCancelRecording: false
            )
        )
        #expect(
            !RecordingStartupContinuationPolicy.shouldContinue(
                activeRecordingStartID: startID,
                startID: startID,
                shouldCancelRecording: true
            )
        )
        #expect(
            !RecordingStartupContinuationPolicy.shouldContinue(
                activeRecordingStartID: UUID(),
                startID: startID,
                shouldCancelRecording: false
            )
        )
    }

    @Test func recordingHardwareStartCoordinatorInvalidatesOlderStartWhenNewStartActivates() {
        let coordinator = RecordingHardwareStartCoordinator()
        let olderStart = RecordingHardwareStartToken()
        let newerStart = RecordingHardwareStartToken()

        coordinator.activate(olderStart)
        #expect(coordinator.isActive(olderStart))

        coordinator.activate(newerStart)

        #expect(olderStart.isCancelled)
        #expect(!coordinator.isActive(olderStart))
        #expect(coordinator.isActive(newerStart))
    }

    @Test func recordingHardwareStartCoordinatorCancelOnlyClearsMatchingStart() {
        let coordinator = RecordingHardwareStartCoordinator()
        let staleStart = RecordingHardwareStartToken()
        let activeStart = RecordingHardwareStartToken()

        coordinator.activate(staleStart)
        coordinator.activate(activeStart)
        coordinator.cancel(staleStart)

        #expect(staleStart.isCancelled)
        #expect(coordinator.isActive(activeStart))

        coordinator.cancel(activeStart)

        #expect(activeStart.isCancelled)
        #expect(!coordinator.isActive(activeStart))
    }

    @Test func recordingShortcutFastStopStateMatchesShortcutModes() {
        let state = RecordingShortcutFastStopState(
            primaryMode: .toggle,
            secondaryMode: .pushToTalk,
            hybridPressThreshold: 0.5
        )

        state.updateRecorderVisible(true)
        state.updateRecordingState(.recording)

        #expect(state.shouldRequestStopOnKeyDown(action: .primaryRecording))
        #expect(!state.shouldRequestStopOnKeyUp(action: .primaryRecording, pressDuration: 0.1))
        #expect(!state.shouldRequestStopOnKeyDown(action: .secondaryRecording))
        #expect(state.shouldRequestStopOnKeyUp(action: .secondaryRecording, pressDuration: 0.1))

        state.updatePrimaryMode(.hybrid)

        #expect(state.shouldRequestStopOnKeyDown(action: .primaryRecording))
        #expect(!state.shouldRequestStopOnKeyUp(action: .primaryRecording, pressDuration: 0.2))
        #expect(state.shouldRequestStopOnKeyUp(action: .primaryRecording, pressDuration: 0.6))
    }

    @Test func recordingShortcutFastStopStateRequiresVisibleActiveRecording() {
        let state = RecordingShortcutFastStopState(
            primaryMode: .toggle,
            secondaryMode: .pushToTalk
        )

        state.updateRecorderVisible(false)
        state.updateRecordingState(.recording)
        #expect(!state.shouldRequestStopOnKeyDown(action: .primaryRecording))

        state.updateRecorderVisible(true)
        state.updateRecordingState(.idle)
        #expect(!state.shouldRequestStopOnKeyDown(action: .primaryRecording))

        state.updateRecordingState(.starting)
        #expect(state.shouldRequestStopOnKeyDown(action: .primaryRecording))
        #expect(!state.shouldRequestStopOnKeyDown(action: .pasteLastTranscription))
    }

    @MainActor
    @Test func recordingShortcutActiveStopKeyDownBypassesStartupCooldown() async {
        for mode in [RecordingShortcutManager.Mode.toggle, .hybrid] {
            var isRecorderVisible = false
            var recordingState = RecordingState.idle
            var toggleCount = 0
            let handler = RecordingShortcutModeHandler(
                canHandleShortcutAction: { true },
                isRecorderVisible: { isRecorderVisible },
                recordingState: { recordingState },
                toggleRecorderPanel: { _ in
                    toggleCount += 1
                    isRecorderVisible.toggle()
                    recordingState = isRecorderVisible ? .recording : .idle
                },
                cancelRecording: {}
            )

            await handler.handleKeyDown(
                action: .primaryRecording,
                eventTime: 10,
                mode: mode
            )
            await handler.handleKeyUp(
                action: .primaryRecording,
                eventTime: 10.1,
                mode: mode
            )
            await handler.handleKeyDown(
                action: .primaryRecording,
                eventTime: 10.2,
                mode: mode
            )

            #expect(toggleCount == 2)
            #expect(!isRecorderVisible)
            #expect(recordingState == .idle)
        }
    }

    @MainActor
    @Test func recordingShortcutActiveStopKeyDownDoesNotRequireHandsFreeState() async {
        for mode in [RecordingShortcutManager.Mode.toggle, .hybrid] {
            var isRecorderVisible = true
            var recordingState = RecordingState.recording
            var toggleCount = 0
            let handler = RecordingShortcutModeHandler(
                canHandleShortcutAction: { true },
                isRecorderVisible: { isRecorderVisible },
                recordingState: { recordingState },
                toggleRecorderPanel: { _ in
                    toggleCount += 1
                    isRecorderVisible.toggle()
                    recordingState = isRecorderVisible ? .recording : .idle
                },
                cancelRecording: {}
            )

            await handler.handleKeyDown(
                action: .primaryRecording,
                eventTime: 20,
                mode: mode
            )
            await handler.handleKeyUp(
                action: .primaryRecording,
                eventTime: 20.1,
                mode: mode
            )

            #expect(toggleCount == 1)
            #expect(!isRecorderVisible)
            #expect(recordingState == .idle)
        }
    }

    @MainActor
    @Test func streamingServiceDrainsBufferedAudioBeforeCommit() async throws {
        let provider = FakeStreamingProvider(commitEvent: .committed(text: "final text"))
        let service = try StreamingTranscriptionService(
            modelContainer: makeModelContainer(),
            providerFactory: { _, _, _ in provider },
            finalCommitTimeoutNanoseconds: 200_000_000
        )

        try await service.startStreaming(
            model: makeCloudModel(name: "deepgram-live", provider: .deepgram),
            context: TranscriptionRequestContext(language: "en", prompt: nil)
        )

        let chunks = [Data([0x01]), Data([0x02, 0x03]), Data([0x04])]
        for chunk in chunks {
            service.sendAudioChunk(chunk)
        }

        let text = try await service.stopAndGetFinalText()

        #expect(text == "final text")
        #expect(provider.sentChunks == chunks)
        #expect(provider.sentChunkCountAtCommit == chunks.count)
        #expect(provider.commitCallCount == 1)
        #expect(await eventually { provider.disconnectCallCount == 1 })
    }

    @MainActor
    @Test func streamingServiceReturnsFinalTextWhenDisconnectTimesOut() async throws {
        let provider = FakeStreamingProvider(
            commitEvent: .committed(text: "final text"),
            disconnectDelayNanoseconds: 200_000_000
        )
        let service = try StreamingTranscriptionService(
            modelContainer: makeModelContainer(),
            providerFactory: { _, _, _ in provider },
            finalCommitTimeoutNanoseconds: 200_000_000,
            disconnectTimeoutNanoseconds: 20_000_000
        )

        try await service.startStreaming(
            model: makeCloudModel(name: "deepgram-live", provider: .deepgram),
            context: TranscriptionRequestContext(language: "en", prompt: nil)
        )

        let startedAt = Date()
        let text = try await service.stopAndGetFinalText()
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(text == "final text")
        #expect(elapsed < 0.15)
        #expect(provider.commitCallCount == 1)
        #expect(await eventually { provider.disconnectCallCount == 1 })
    }

    @MainActor
    @Test func streamingServiceSendsAudioBufferedBeforeConnection() async throws {
        let provider = FakeStreamingProvider(commitEvent: .committed(text: "final text"))
        let service = try StreamingTranscriptionService(
            modelContainer: makeModelContainer(),
            providerFactory: { _, _, _ in provider },
            finalCommitTimeoutNanoseconds: 200_000_000
        )

        let earlyChunk = Data([0x7A, 0x7B])
        service.sendAudioChunk(earlyChunk)

        try await service.startStreaming(
            model: makeCloudModel(name: "deepgram-live", provider: .deepgram),
            context: TranscriptionRequestContext(language: "en", prompt: nil)
        )

        let text = try await service.stopAndGetFinalText()

        #expect(text == "final text")
        #expect(provider.sentChunks == [earlyChunk])
        #expect(provider.sentChunkCountAtCommit == 1)
    }

    @MainActor
    @Test func streamingSessionFallsBackWhenBufferedAudioDropsBeforeConnection() async throws {
        let connectGate = FakeStreamingConnectGate()
        let provider = FakeStreamingProvider(
            commitEvent: .committed(text: "streaming transcript"),
            connectGate: connectGate
        )
        let streamingService = try StreamingTranscriptionService(
            modelContainer: makeModelContainer(),
            providerFactory: { _, _, _ in provider },
            maxBufferedChunks: 1,
            finalCommitTimeoutNanoseconds: 200_000_000
        )
        let fallbackService = FakeBatchTranscriptionService(result: "batch transcript")
        let streamingModel = makeCloudModel(name: "deepgram-live", provider: .deepgram)
        let session = StreamingTranscriptionSession(
            streamingService: streamingService,
            fallbackService: fallbackService
        )

        let preparedCallback = try await session.prepare(
            configuration: TranscriptionRuntimeConfiguration(
                mode: nil,
                model: streamingModel,
                language: "en",
                isRealtimeEnabled: true
            )
        )
        let callback = try #require(preparedCallback)
        callback(Data([0x01]))
        callback(Data([0x02]))
        connectGate.release()

        let text = try await session.transcribe(audioURL: URL(fileURLWithPath: "/tmp/voiceink-test.wav"))
        let disconnectDeadline = ProcessInfo.processInfo.systemUptime + 1
        while provider.disconnectCallCount == 0,
              ProcessInfo.processInfo.systemUptime < disconnectDeadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        #expect(text == "batch transcript")
        // Once continuity is lost, the bounded queue seals immediately. Sending
        // only the newest fragment would create a known-incomplete stream.
        #expect(provider.sentChunks.isEmpty)
        #expect(provider.commitCallCount == 0)
        #expect(provider.disconnectCallCount == 1)
        #expect(fallbackService.transcribeCallCount == 1)
    }

    @MainActor
    @Test func streamingServiceTimesOutWhenFinalCommitNeverArrives() async throws {
        let provider = FakeStreamingProvider(
            commitEvent: nil,
            emitsFinalizedOnCommit: false
        )
        let service = try StreamingTranscriptionService(
            modelContainer: makeModelContainer(),
            providerFactory: { _, _, _ in provider },
            finalCommitTimeoutNanoseconds: 20_000_000
        )

        try await service.startStreaming(
            model: makeCloudModel(name: "deepgram-live", provider: .deepgram),
            context: TranscriptionRequestContext(language: "en", prompt: nil)
        )

        do {
            _ = try await service.stopAndGetFinalText()
            Issue.record("Expected stopAndGetFinalText to time out when no final commit event arrives")
        } catch StreamingTranscriptionError.timeout {
            #expect(provider.commitCallCount == 1)
            #expect(await eventually { provider.disconnectCallCount == 1 })
        } catch {
            Issue.record("Expected StreamingTranscriptionError.timeout, got \(error)")
        }
    }

    @MainActor
    @Test func streamingServiceTimesOutWhenFinalCommitAckNeverArrivesAfterPriorCommit() async throws {
        let provider = FakeStreamingProvider(
            commitEvent: nil,
            emitsFinalizedOnCommit: false
        )
        let service = try StreamingTranscriptionService(
            modelContainer: makeModelContainer(),
            providerFactory: { _, _, _ in provider },
            finalCommitTimeoutNanoseconds: 20_000_000
        )

        try await service.startStreaming(
            model: makeCloudModel(name: "deepgram-live", provider: .deepgram),
            context: TranscriptionRequestContext(language: "en", prompt: nil)
        )
        provider.emit(.committed(text: "already committed"))
        try await Task.sleep(nanoseconds: 20_000_000)

        do {
            _ = try await service.stopAndGetFinalText()
            Issue.record("Expected final commit ack timeout even when older committed text exists")
        } catch StreamingTranscriptionError.timeout {
            #expect(provider.commitCallCount == 1)
            #expect(await eventually { provider.disconnectCallCount == 1 })
        } catch {
            Issue.record("Expected StreamingTranscriptionError.timeout, got \(error)")
        }
    }

    @MainActor
    @Test func streamingSessionReturnsAudioCallbackBeforeStreamingStart() async throws {
        let streamingService = DelayedStartStreamingService()
        let fallbackService = FakeBatchTranscriptionService(result: "batch transcript")
        let streamingModel = makeCloudModel(name: "deepgram-live", provider: .deepgram)
        let session = StreamingTranscriptionSession(
            streamingService: streamingService,
            fallbackService: fallbackService
        )

        let prepareTask = Task { @MainActor in
            try await session.prepare(
                configuration: TranscriptionRuntimeConfiguration(
                    mode: nil,
                    model: streamingModel,
                    language: "en",
                    isRealtimeEnabled: true
                )
            )
        }

        let preparedCallback = try await prepareTask.value
        let callback = try #require(preparedCallback)
        let chunk = Data([0x2A])
        callback(chunk)

        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(streamingService.startCallCount == 1)
        #expect(streamingService.sentChunks == [chunk])

        streamingService.releaseStart()
        let text = try await session.transcribe(audioURL: URL(fileURLWithPath: "/tmp/voiceink-test.wav"))

        #expect(text == "streaming transcript")
    }

    @MainActor
    @Test func streamingSessionStopsReusingPreparedSessionAfterStartFailure() async throws {
        let provider = FakeStreamingProvider(
            commitEvent: .committed(text: "streaming transcript"),
            connectError: StreamingTranscriptionError.connectionFailed("connect failed")
        )
        let streamingService = try StreamingTranscriptionService(
            modelContainer: makeModelContainer(),
            providerFactory: { _, _, _ in provider },
            finalCommitTimeoutNanoseconds: 200_000_000
        )
        let fallbackService = FakeBatchTranscriptionService(result: "batch transcript")
        let streamingModel = makeCloudModel(name: "deepgram-live", provider: .deepgram)
        let session = StreamingTranscriptionSession(
            streamingService: streamingService,
            fallbackService: fallbackService
        )

        let preparedCallback = try await session.prepare(
            configuration: TranscriptionRuntimeConfiguration(
                mode: nil,
                model: streamingModel,
                language: "en",
                isRealtimeEnabled: true
            )
        )
        let callback = try #require(preparedCallback)
        callback(Data([0x01]))

        let text = try await session.transcribe(audioURL: URL(fileURLWithPath: "/tmp/voiceink-test.wav"))

        #expect(text == "batch transcript")
        #expect(!session.canReusePreparedSession())
        #expect(await eventually { provider.disconnectCallCount == 1 })
        #expect(fallbackService.transcribeCallCount == 1)
    }

    @MainActor
    @Test func streamingSessionFallsBackAndCancelsWhenStreamingStartTimesOut() async throws {
        let streamingService = DelayedStartStreamingService()
        let fallbackService = FakeBatchTranscriptionService(result: "batch transcript")
        let streamingModel = makeCloudModel(name: "deepgram-live", provider: .deepgram)
        let session = StreamingTranscriptionSession(
            streamingService: streamingService,
            fallbackService: fallbackService,
            streamingStartTimeoutNanoseconds: 20_000_000
        )

        let preparedCallback = try await session.prepare(
            configuration: TranscriptionRuntimeConfiguration(
                mode: nil,
                model: streamingModel,
                language: "en",
                isRealtimeEnabled: true
            )
        )
        let callback = try #require(preparedCallback)
        callback(Data([0x01]))

        let text = try await session.transcribe(audioURL: URL(fileURLWithPath: "/tmp/voiceink-test.wav"))

        #expect(text == "batch transcript")
        #expect(streamingService.cancelCallCount >= 1)
        #expect(streamingService.stopCallCount == 0)
        #expect(fallbackService.transcribeCallCount == 1)
    }

    @MainActor
    @Test func streamingServiceFailsWithoutCommitWhenAudioSendFails() async throws {
        let provider = FakeStreamingProvider(
            commitEvent: .committed(text: "should not commit"),
            sendError: StreamingTranscriptionError.connectionFailed("dead socket")
        )
        let service = try StreamingTranscriptionService(
            modelContainer: makeModelContainer(),
            providerFactory: { _, _, _ in provider },
            finalCommitTimeoutNanoseconds: 200_000_000
        )

        try await service.startStreaming(
            model: makeCloudModel(name: "deepgram-live", provider: .deepgram),
            context: TranscriptionRequestContext(language: "en", prompt: nil)
        )

        service.sendAudioChunk(Data([0x01]))

        do {
            _ = try await service.stopAndGetFinalText()
            Issue.record("Expected stopAndGetFinalText to fail when sending audio fails")
        } catch StreamingTranscriptionError.connectionFailed(let message) {
            #expect(message == "dead socket")
            #expect(provider.commitCallCount == 0)
            #expect(await eventually { provider.disconnectCallCount == 1 })
        } catch {
            Issue.record("Expected StreamingTranscriptionError.connectionFailed, got \(error)")
        }
    }

    @MainActor
    @Test func streamingServiceFailsWhenProviderErrorsAfterCommitEvent() async throws {
        let provider = FakeStreamingProvider(
            commitEvents: [
                .error(StreamingTranscriptionError.serverError("commit failed"))
            ]
        )
        let service = try StreamingTranscriptionService(
            modelContainer: makeModelContainer(),
            providerFactory: { _, _, _ in provider },
            finalCommitTimeoutNanoseconds: 200_000_000
        )

        try await service.startStreaming(
            model: makeCloudModel(name: "deepgram-live", provider: .deepgram),
            context: TranscriptionRequestContext(language: "en", prompt: nil)
        )
        provider.emit(.committed(text: "partial final"))
        try await Task.sleep(nanoseconds: 20_000_000)

        do {
            _ = try await service.stopAndGetFinalText()
            Issue.record("Expected provider error after commit event to fail the streaming session")
        } catch StreamingTranscriptionError.serverError(let message) {
            #expect(message == "commit failed")
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while provider.disconnectCallCount == 0,
                  ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            #expect(provider.disconnectCallCount == 1)
        } catch {
            Issue.record("Expected StreamingTranscriptionError.serverError, got \(error)")
        }
    }

    @MainActor
    @Test func streamingServiceCancelsPendingPartialWhenCommitArrives() async throws {
        let provider = FakeStreamingProvider(commitEvent: .committed(text: "hello world"))
        var partials: [String] = []
        let service = try StreamingTranscriptionService(
            modelContainer: makeModelContainer(),
            onPartialTranscript: { partial in
                partials.append(partial)
            },
            providerFactory: { _, _, _ in provider },
            finalCommitTimeoutNanoseconds: 200_000_000
        )

        try await service.startStreaming(
            model: makeCloudModel(name: "deepgram-live", provider: .deepgram),
            context: TranscriptionRequestContext(language: "en", prompt: nil)
        )

        provider.emit(.partial(text: "hello"))
        try await Task.sleep(nanoseconds: 10_000_000)
        provider.emit(.partial(text: "hello wor"))
        provider.emit(.committed(text: "hello world"))
        try await Task.sleep(nanoseconds: 150_000_000)

        #expect(partials.contains("hello world"))
        #expect(!partials.contains("hello world hello wor"))
    }

    @MainActor
    @Test func partialCoalescerCancelsImmediatePartialBeforeMainActorDelivery() async {
        let coalescer = StreamingPartialEventCoalescer(interval: 0.1)
        var partials: [String] = []

        coalescer.submit("stale partial") { partial in
            partials.append(partial)
        }
        coalescer.cancel()
        await Task.yield()

        #expect(partials.isEmpty)
    }

    @MainActor
    @Test func streamingSessionReturnsEmptyTextWithoutBatchFallbackWhenStreamingFinalizesEmpty() async throws {
        let streamingService = FakeStreamingService(stopResult: .success("  \n"))
        let fallbackService = FakeBatchTranscriptionService(result: "batch transcript")
        let streamingModel = makeCloudModel(name: "deepgram-live", provider: .deepgram)
        let session = StreamingTranscriptionSession(
            streamingService: streamingService,
            fallbackService: fallbackService
        )

        let preparedCallback = try await session.prepare(
            configuration: TranscriptionRuntimeConfiguration(
                mode: nil,
                model: streamingModel,
                language: "en",
                isRealtimeEnabled: true
            )
        )
        let callback = try #require(preparedCallback)
        let chunk = Data([0x2A])
        callback(chunk)

        let text = try await session.transcribe(audioURL: URL(fileURLWithPath: "/tmp/voiceink-test.wav"))

        #expect(text == "")
        #expect(streamingService.sentChunks == [chunk])
        #expect(streamingService.stopCallCount == 1)
        #expect(streamingService.cancelCallCount == 0)
        #expect(fallbackService.transcribeCallCount == 0)
        #expect(fallbackService.modelNames.isEmpty)
    }

    @MainActor
    @Test func streamingSessionCancellationNeverUploadsBatchFallback() async throws {
        let streamingService = FakeStreamingService(
            stopResult: .failure(CancellationError())
        )
        let fallbackService = FakeBatchTranscriptionService(result: "must not upload")
        let session = StreamingTranscriptionSession(
            streamingService: streamingService,
            fallbackService: fallbackService
        )
        _ = try await session.prepare(
            configuration: TranscriptionRuntimeConfiguration(
                mode: nil,
                model: makeCloudModel(name: "deepgram-live", provider: .deepgram),
                language: "en",
                isRealtimeEnabled: true
            )
        )

        session.cancel()

        do {
            _ = try await session.transcribe(
                audioURL: URL(fileURLWithPath: "/tmp/voiceink-cancelled.wav")
            )
            Issue.record("Expected cancellation to remain terminal")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(fallbackService.transcribeCallCount == 0)
    }

    @MainActor
    @Test func streamingSessionFallsBackToBatchWhenStreamingStopTimesOut() async throws {
        let streamingService = FakeStreamingService(stopResult: .failure(StreamingTranscriptionError.timeout))
        let fallbackService = FakeBatchTranscriptionService(result: "batch transcript")
        let streamingModel = makeCloudModel(name: "deepgram-live", provider: .deepgram)
        let session = StreamingTranscriptionSession(
            streamingService: streamingService,
            fallbackService: fallbackService
        )

        _ = try await session.prepare(
            configuration: TranscriptionRuntimeConfiguration(
                mode: nil,
                model: streamingModel,
                language: "en",
                isRealtimeEnabled: true
            )
        )

        let text = try await session.transcribe(audioURL: URL(fileURLWithPath: "/tmp/voiceink-test.wav"))

        #expect(text == "batch transcript")
        #expect(streamingService.stopCallCount == 1)
        #expect(streamingService.cancelCallCount == 1)
        #expect(fallbackService.transcribeCallCount == 1)
        #expect(fallbackService.modelNames == ["deepgram-live"])
    }

    @Test func transcriptionRuntimeConfigurationScopesDefaultPromptToWhisper() {
        let whisperConfiguration = TranscriptionRuntimeConfiguration(
            mode: nil,
            model: makeWhisperTestModel(),
            language: "en",
            isRealtimeEnabled: true
        )
        let cloudConfiguration = TranscriptionRuntimeConfiguration(
            mode: nil,
            model: makeCloudModel(name: "deepgram-live", provider: .deepgram),
            language: "en",
            isRealtimeEnabled: true
        )

        #expect(whisperConfiguration.requestContext.prompt == WhisperPrompt.resolvedPrompt(for: "en"))
        #expect(whisperConfiguration.requestContext.prompt?.isEmpty == false)
        #expect(cloudConfiguration.requestContext.prompt == nil)
    }

    @MainActor
    @Test func realtimePreconnectDiscardCancelsAlreadyPreparedSession() async throws {
        let configuration = makeRealtimeConfiguration()
        let session = FakeTranscriptionSession()
        let preparedSession = PreparedRealtimeSession(
            configuration: configuration,
            session: session,
            audioChunkCallback: { _ in }
        )
        let preconnect = RecordingRealtimePreconnectLifecycle.begin(
            configuration: configuration,
            startupStartedAt: ProcessInfo.processInfo.systemUptime,
            prepare: { preparedSession }
        )
        _ = try await preconnect.task.value

        var discardedPreparedSession = false
        let cleanup = RecordingRealtimePreconnectLifecycle.discard(preconnect) { _ in
            discardedPreparedSession = true
        }
        await cleanup?.value

        #expect(discardedPreparedSession)
        #expect(session.cancelCallCount == 1)
    }

    @MainActor
    @Test func realtimePreconnectDiscardCancelsSessionPreparedAfterTaskCancellation() async throws {
        let configuration = makeRealtimeConfiguration()
        let session = FakeTranscriptionSession()
        let preparedSession = PreparedRealtimeSession(
            configuration: configuration,
            session: session,
            audioChunkCallback: { _ in }
        )
        let (startedStream, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        var prepareContinuation: CheckedContinuation<PreparedRealtimeSession?, Never>?

        let preconnect = RecordingRealtimePreconnectLifecycle.begin(
            configuration: configuration,
            startupStartedAt: ProcessInfo.processInfo.systemUptime,
            prepare: {
                await withCheckedContinuation { continuation in
                    prepareContinuation = continuation
                    startedContinuation.yield(())
                }
            }
        )

        var startedIterator = startedStream.makeAsyncIterator()
        _ = await startedIterator.next()
        startedContinuation.finish()

        let cleanup = RecordingRealtimePreconnectLifecycle.discard(preconnect)
        let continuation = try #require(prepareContinuation)
        continuation.resume(returning: preparedSession)
        await cleanup?.value

        do {
            _ = try await preconnect.task.value
            Issue.record("Expected cancelled preconnect task to throw CancellationError")
        } catch is CancellationError {
            #expect(session.cancelCallCount == 1)
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test func realtimePreconnectConfigurationMatchingIncludesStreamingInputs() {
        let baseConfiguration = makeRealtimeConfiguration(
            model: makeCloudModel(name: "deepgram-live", provider: .deepgram),
            language: "en",
            isRealtimeEnabled: true,
            prompt: "domain prompt"
        )

        #expect(
            RecordingRealtimePreconnectLifecycle.configurationsMatch(
                baseConfiguration,
                makeRealtimeConfiguration(
                    model: makeCloudModel(name: "deepgram-live", provider: .deepgram),
                    language: "en",
                    isRealtimeEnabled: true,
                    prompt: "domain prompt"
                )
            )
        )
        #expect(
            !RecordingRealtimePreconnectLifecycle.configurationsMatch(
                baseConfiguration,
                makeRealtimeConfiguration(
                    model: makeCloudModel(name: "deepgram-live", provider: .deepgram),
                    language: "en",
                    isRealtimeEnabled: false,
                    prompt: "domain prompt"
                )
            )
        )
        #expect(
            !RecordingRealtimePreconnectLifecycle.configurationsMatch(
                baseConfiguration,
                makeRealtimeConfiguration(
                    model: makeCloudModel(name: "nova-3", provider: .deepgram),
                    language: "en",
                    isRealtimeEnabled: true,
                    prompt: "domain prompt"
                )
            )
        )
        #expect(
            !RecordingRealtimePreconnectLifecycle.configurationsMatch(
                baseConfiguration,
                makeRealtimeConfiguration(
                    model: makeCloudModel(name: "deepgram-live", provider: .elevenLabs),
                    language: "en",
                    isRealtimeEnabled: true,
                    prompt: "domain prompt"
                )
            )
        )
        #expect(
            !RecordingRealtimePreconnectLifecycle.configurationsMatch(
                baseConfiguration,
                makeRealtimeConfiguration(
                    model: makeCloudModel(name: "deepgram-live", provider: .deepgram),
                    language: "ja",
                    isRealtimeEnabled: true,
                    prompt: "domain prompt"
                )
            )
        )
        #expect(
            !RecordingRealtimePreconnectLifecycle.configurationsMatch(
                baseConfiguration,
                makeRealtimeConfiguration(
                    model: makeCloudModel(name: "deepgram-live", provider: .deepgram),
                    language: "en",
                    isRealtimeEnabled: true,
                    prompt: "other prompt"
                )
            )
        )
    }

    @Test func audioVisualizerBarModelIsDeterministicAndInputDriven() {
        let weights = AudioVisualizerBarModel.barWeights(count: 18)
        let repeatedWeights = AudioVisualizerBarModel.barWeights(count: 18)

        #expect(weights == repeatedWeights)
        #expect(weights.count == 18)

        let minHeight = CGFloat(4)
        let maxHeight = CGFloat(28)
        let quietHeight = AudioVisualizerBarModel.barHeight(
            for: 8,
            weights: weights,
            level: 0,
            motionAmount: 0,
            isActive: true,
            minHeight: minHeight,
            maxHeight: maxHeight
        )
        let repeatedQuietHeight = AudioVisualizerBarModel.barHeight(
            for: 8,
            weights: weights,
            level: 0,
            motionAmount: 0,
            isActive: true,
            minHeight: minHeight,
            maxHeight: maxHeight
        )
        let activeHeight = AudioVisualizerBarModel.barHeight(
            for: 8,
            weights: weights,
            level: 0.6,
            motionAmount: 0,
            isActive: true,
            minHeight: minHeight,
            maxHeight: maxHeight
        )
        let inactiveHeight = AudioVisualizerBarModel.barHeight(
            for: 8,
            weights: weights,
            level: 1,
            motionAmount: 1,
            isActive: false,
            minHeight: minHeight,
            maxHeight: maxHeight
        )
        let invalidIndexHeight = AudioVisualizerBarModel.barHeight(
            for: weights.count,
            weights: weights,
            level: 1,
            motionAmount: 1,
            isActive: true,
            minHeight: minHeight,
            maxHeight: maxHeight
        )

        #expect(quietHeight == repeatedQuietHeight)
        #expect(quietHeight == minHeight)
        #expect(activeHeight > minHeight)
        #expect(activeHeight <= maxHeight)
        #expect(inactiveHeight == minHeight)
        #expect(invalidIndexHeight == minHeight)
    }

    @Test func audioVisualizerBarModelPreservesLocalMotionForActiveInput() {
        let weights = AudioVisualizerBarModel.barWeights(count: 15)
        let minHeight = CGFloat(4)
        let maxHeight = CGFloat(28)

        let firstFrame = weights.indices.map { index in
            AudioVisualizerBarModel.barHeight(
                for: index,
                weights: weights,
                level: 0.64,
                motionAmount: 1,
                isActive: true,
                minHeight: minHeight,
                maxHeight: maxHeight,
                time: 1.0
            )
        }
        let secondFrame = weights.indices.map { index in
            AudioVisualizerBarModel.barHeight(
                for: index,
                weights: weights,
                level: 0.64,
                motionAmount: 1,
                isActive: true,
                minHeight: minHeight,
                maxHeight: maxHeight,
                time: 1.0 + AudioVisualizerBarModel.animationInterval * 3
            )
        }
        let quietFrame = weights.indices.map { index in
            AudioVisualizerBarModel.barHeight(
                for: index,
                weights: weights,
                level: 0,
                motionAmount: 1,
                isActive: true,
                minHeight: minHeight,
                maxHeight: maxHeight,
                time: 1.0
            )
        }

        let maxFrameDelta = zip(firstFrame, secondFrame)
            .map { abs($0 - $1) }
            .max() ?? 0

        #expect(maxFrameDelta > 1.0)
        #expect(firstFrame.allSatisfy { $0 >= minHeight && $0 <= maxHeight })
        #expect(secondFrame.allSatisfy { $0 >= minHeight && $0 <= maxHeight })
        #expect(quietFrame.allSatisfy { $0 == minHeight })
    }

    @Test func audioVisualizerMeterKeepsNoiseLikeSilenceStatic() {
        var state = AudioVisualizerMeterState()
        let snapshots = (0..<24).map { _ in
            state.update(averageDb: -45, peakDb: -42)
        }

        #expect(snapshots.allSatisfy { $0.level == 0 })
        #expect(snapshots.allSatisfy { $0.motionAmount == 0 })
        #expect(snapshots.allSatisfy { !$0.isSpeechActive })
    }

    @Test func audioVisualizerMeterAdaptsToLouderRoomNoiseWithoutAnimating() {
        let loudRoomProfile = AudioVisualizerMeterProfile(initialNoiseFloorDb: -42)
        var state = AudioVisualizerMeterState(profile: loudRoomProfile)
        let snapshots = (0..<20).map { _ in
            state.update(averageDb: -38, peakDb: -35)
        }

        #expect(snapshots.allSatisfy { $0.level == 0 })
        #expect(snapshots.allSatisfy { !$0.isSpeechActive })
        #expect(state.noiseFloorDb > -43)
    }

    @Test func audioVisualizerMeterRampsIntoSpeechWithoutASuddenJump() {
        let profile = AudioVisualizerMeterProfile()
        var state = AudioVisualizerMeterState(profile: profile)

        for _ in 0..<8 {
            _ = state.update(averageDb: -45, peakDb: -42)
        }

        let first = state.update(averageDb: -30, peakDb: -18)
        let second = state.update(averageDb: -30, peakDb: -18)
        let third = state.update(averageDb: -30, peakDb: -18)

        #expect(first.isSpeechActive)
        #expect(first.level <= profile.maximumRisePerSample + 0.0001)
        #expect(second.level > first.level)
        #expect(third.level > second.level)
        #expect(third.level - first.level <= profile.maximumRisePerSample * 2 + 0.0001)
    }

    @Test func audioVisualizerMeterLearnsStartupLowCrestRoomToneWithoutAnimating() {
        var state = AudioVisualizerMeterState()
        let snapshots = (0..<20).map { _ in
            state.update(averageDb: -44.5, peakDb: -41.5)
        }

        #expect(snapshots.allSatisfy { !$0.isSpeechActive })
        #expect(snapshots.allSatisfy { $0.level == 0 })
        #expect(state.noiseFloorDb > -49)
    }

    @Test func audioVisualizerMeterLearnsColdStartCandidateWindowRoomToneWithoutAnimating() {
        var state = AudioVisualizerMeterState()
        let snapshots = (0..<20).map { _ in
            state.update(averageDb: -42, peakDb: -39)
        }

        #expect(snapshots.allSatisfy { !$0.isSpeechActive })
        #expect(snapshots.allSatisfy { $0.level == 0 })
        #expect(state.noiseFloorDb > -46)
    }

    @Test func audioVisualizerMeterDoesNotEatColdStartLowCrestSpeech() {
        var state = AudioVisualizerMeterState()

        let first = state.update(averageDb: -43.5, peakDb: -40.5)
        let second = state.update(averageDb: -43, peakDb: -40)
        let third = state.update(averageDb: -42.75, peakDb: -39.75)

        #expect(!first.isSpeechActive)
        #expect(!second.isSpeechActive)
        #expect(third.isSpeechActive)
        #expect(third.level > 0)
        #expect(state.noiseFloorDb == AudioVisualizerMeterProfile().initialNoiseFloorDb)
    }

    @Test func audioVisualizerMeterReleasesColdStartSpeechToRoomTone() {
        var state = AudioVisualizerMeterState()

        _ = state.update(averageDb: -43.5, peakDb: -40.5)
        _ = state.update(averageDb: -43, peakDb: -40)
        _ = state.update(averageDb: -42.75, peakDb: -39.75)
        let activeSpeech = state.update(averageDb: -43, peakDb: -40)
        let release = state.update(averageDb: -44.5, peakDb: -41.5)
        let tail = (0..<24).map { _ in
            state.update(averageDb: -44.5, peakDb: -41.5)
        }

        #expect(activeSpeech.isSpeechActive)
        #expect(!release.isSpeechActive)
        #expect(release.level > 0)
        #expect(tail.allSatisfy { !$0.isSpeechActive })
        #expect(tail.last?.level == 0)
        #expect(state.noiseFloorDb > -49)
    }

    @Test func audioVisualizerMeterReleasesColdStartImpulseToCandidateWindowRoomTone() {
        var state = AudioVisualizerMeterState()

        let impulse = state.update(averageDb: -43, peakDb: -25)
        let release = state.update(averageDb: -42, peakDb: -39)
        let tail = (0..<24).map { _ in
            state.update(averageDb: -42, peakDb: -39)
        }

        #expect(impulse.isSpeechActive)
        #expect(!release.isSpeechActive)
        #expect(release.level > 0)
        #expect(tail.allSatisfy { !$0.isSpeechActive })
        #expect(tail.last?.level == 0)
        #expect(state.noiseFloorDb > -46)
    }

    @Test func audioVisualizerMeterReleasesColdStartImpulseToRoomTone() {
        var state = AudioVisualizerMeterState()

        let impulse = state.update(averageDb: -43, peakDb: -25)
        let release = state.update(averageDb: -44.5, peakDb: -41.5)
        let tail = (0..<24).map { _ in
            state.update(averageDb: -44.5, peakDb: -41.5)
        }

        #expect(impulse.isSpeechActive)
        #expect(!release.isSpeechActive)
        #expect(release.level > 0)
        #expect(tail.allSatisfy { !$0.isSpeechActive })
        #expect(tail.last?.level == 0)
        #expect(state.noiseFloorDb > -49)
    }

    @Test func audioVisualizerMeterReleasesColdStartImpulseToLoudRoomTone() {
        var state = AudioVisualizerMeterState()

        let impulse = state.update(averageDb: -43, peakDb: -25)
        let release = state.update(averageDb: -38, peakDb: -35)
        let tail = (0..<24).map { _ in
            state.update(averageDb: -38, peakDb: -35)
        }

        #expect(impulse.isSpeechActive)
        #expect(!release.isSpeechActive)
        #expect(release.level > 0)
        #expect(tail.allSatisfy { !$0.isSpeechActive })
        #expect(tail.last?.level == 0)
        #expect(state.noiseFloorDb > -43)
    }

    @Test func audioVisualizerMeterLearnsStartupLoudLowCrestRoomToneWithoutAnimating() {
        var state = AudioVisualizerMeterState()
        let snapshots = (0..<20).map { _ in
            state.update(averageDb: -38, peakDb: -35)
        }

        #expect(snapshots.allSatisfy { !$0.isSpeechActive })
        #expect(snapshots.allSatisfy { $0.level == 0 })
        #expect(state.noiseFloorDb > -43)
    }

    @Test func audioVisualizerMeterDoesNotEatLowCrestSpeechAfterNoiseCalibration() {
        var state = AudioVisualizerMeterState()

        for _ in 0..<20 {
            _ = state.update(averageDb: -45, peakDb: -42)
        }
        let calibratedNoiseFloor = state.noiseFloorDb

        let first = state.update(averageDb: -43, peakDb: -40)
        let second = state.update(averageDb: -43, peakDb: -40)
        let third = state.update(averageDb: -43, peakDb: -40)

        #expect(!first.isSpeechActive)
        #expect(!second.isSpeechActive)
        #expect(third.isSpeechActive)
        #expect(third.level > 0)
        #expect(state.noiseFloorDb == calibratedNoiseFloor)
    }

    @Test func audioVisualizerMeterRecognizesQuietLowCrestSpeechAtDisplayCadence() {
        var state = AudioVisualizerMeterState()
        var snapshots: [AudioVisualizerMeterSnapshot] = []

        func feed(averageDb: Double, peakDb: Double, at time: TimeInterval) {
            snapshots.append(state.update(averageDb: averageDb, peakDb: peakDb, at: time))
        }

        for tick in 0...60 {
            feed(
                averageDb: -70,
                peakDb: -67,
                at: Double(tick) * AudioMeterCadence.interval
            )
        }
        let quietSnapshotCount = snapshots.count
        let calibratedNoiseFloor = state.noiseFloorDb

        for tick in 61...90 {
            feed(
                averageDb: -62,
                peakDb: -59,
                at: Double(tick) * AudioMeterCadence.interval
            )
        }

        #expect(quietSnapshotCount == 61)
        #expect(snapshots.prefix(quietSnapshotCount).allSatisfy { !$0.isSpeechActive })
        #expect(calibratedNoiseFloor < -66)
        #expect(snapshots.suffix(from: quietSnapshotCount).contains { $0.isSpeechActive })
        #expect(snapshots.last?.level ?? 0 > 0)
    }

    @Test func audioVisualizerMeterRecognizesCompressedSpeechInLoudRoom() {
        let loudRoomProfile = AudioVisualizerMeterProfile(initialNoiseFloorDb: -44)
        var state = AudioVisualizerMeterState(profile: loudRoomProfile)
        for _ in 0..<8 {
            _ = state.update(averageDb: -44, peakDb: -41)
        }
        let first = state.update(averageDb: -36, peakDb: -31)
        let second = state.update(averageDb: -36, peakDb: -31)
        let third = state.update(averageDb: -36, peakDb: -31)

        #expect(first.isSpeechActive)
        #expect(second.isSpeechActive)
        #expect(third.isSpeechActive)
        #expect(third.level > 0)
    }

    @Test func audioVisualizerMeterDoesNotEatQuietRoomLowCrestSpeech() {
        var state = AudioVisualizerMeterState()

        for _ in 0..<32 {
            _ = state.update(averageDb: -70, peakDb: -67)
        }
        let calibratedNoiseFloor = state.noiseFloorDb

        let first = state.update(averageDb: -62, peakDb: -59)
        let second = state.update(averageDb: -62, peakDb: -59)
        let third = state.update(averageDb: -62, peakDb: -59)

        #expect(calibratedNoiseFloor < -66)
        #expect(calibratedNoiseFloor > -69)
        #expect(!first.isSpeechActive)
        #expect(!second.isSpeechActive)
        #expect(third.isSpeechActive)
        #expect(third.level > 0)
        #expect(state.noiseFloorDb == calibratedNoiseFloor)
    }

    @Test func audioVisualizerMeterNoiseLearningDoesNotChangeVisibleSnapshot() {
        var state = AudioVisualizerMeterState()
        let first = state.update(averageDb: -45, peakDb: -42)
        let floorAfterFirstSample = state.noiseFloorDb
        let second = state.update(averageDb: -45, peakDb: -42)

        #expect(first == .silent)
        #expect(second == .silent)
        #expect(floorAfterFirstSample != state.noiseFloorDb)
    }

    @Test func audioVisualizerMeterReleasesSpeechGraduallyToSilence() {
        var state = AudioVisualizerMeterState()

        for _ in 0..<8 {
            _ = state.update(averageDb: -30, peakDb: -18)
        }
        let active = state.update(averageDb: -30, peakDb: -18)
        let release = state.update(averageDb: -70, peakDb: -67)
        let silentTail = (0..<48).map { _ in
            state.update(averageDb: -70, peakDb: -67)
        }

        #expect(active.level > 0.4)
        #expect(!release.isSpeechActive)
        #expect(release.level > 0)
        #expect(release.level < active.level)
        #expect(silentTail.last?.level == 0)
    }

    @Test func audioVisualizerMeterReleaseUsesDisplayElapsedTime() {
        var state = AudioVisualizerMeterState()
        var snapshots: [AudioVisualizerMeterSnapshot] = []

        func feed(averageDb: Double, peakDb: Double, at time: TimeInterval) {
            snapshots.append(state.update(averageDb: averageDb, peakDb: peakDb, at: time))
        }

        feed(averageDb: -30, peakDb: -18, at: 0)
        for tick in 1...12 {
            feed(averageDb: -30, peakDb: -18, at: Double(tick) * AudioMeterCadence.interval)
        }
        feed(averageDb: -30, peakDb: -18, at: 0.231)
        let activeLevel = snapshots.last?.level ?? 0

        feed(averageDb: -70, peakDb: -67, at: 0.264)
        for tick in 17...80 {
            feed(averageDb: -70, peakDb: -67, at: Double(tick) * AudioMeterCadence.interval)
        }

        #expect(activeLevel > 0.3)
        #expect((snapshots.last?.level ?? 1) == 0)
    }

    @Test func audioVisualizerMeterPreservesCloseQuietSpeechImpulse() {
        var state = AudioVisualizerMeterState()

        for _ in 0..<10 {
            _ = state.update(averageDb: -45, peakDb: -42)
        }
        let impulse = state.update(averageDb: -43, peakDb: -25)

        #expect(impulse.isSpeechActive)
        #expect(impulse.level > 0)
        #expect(impulse.level < 0.15)
    }

    @Test func voiceInkEngineOverlapsRealtimePreconnectWithHardwareStartup() throws {
        let source = try readProjectSource("VoiceInk/Transcription/Engine/VoiceInkEngine.swift")
        let hardwareStartIssued = try #require(
            source.range(of: "self.recorder.beginStartRecording")
        )
        let preconnectStarted = try #require(
            source.range(of: "initialRealtimePreconnect = self.beginInitialRealtimePreconnect")
        )
        let hardwareStartAwaited = try #require(
            source.range(of: "try await hardwareStart.value()")
        )

        #expect(hardwareStartIssued.lowerBound < preconnectStarted.lowerBound)
        #expect(preconnectStarted.lowerBound < hardwareStartAwaited.lowerBound)
    }

    @Test func audioVisualizerUsesOneDisplayClockAndLatestValueSource() throws {
        let source = try readProjectSource("VoiceInk/Views/Recorder/AudioVisualizerView.swift")

        #expect(source.contains("TimelineView(.animation(minimumInterval: AudioMeterCadence.interval))"))
        #expect(source.contains("source.snapshot()"))
        #expect(source.contains("AudioVisualizerMeterStore"))
        #expect(!source.contains(".animation(.easeOut"))
    }

    @Test func recorderViewsObserveAudioMeterOnlyInsideStatusDisplay() throws {
        let notchSource = try readProjectSource("VoiceInk/Views/Recorder/NotchRecorderView.swift")
        let miniSource = try readProjectSource("VoiceInk/Views/Recorder/MiniRecorderView.swift")
        let componentsSource = try readProjectSource("VoiceInk/Views/Recorder/RecorderComponents.swift")

        #expect(!notchSource.contains("@ObservedObject var recorder: Recorder"))
        #expect(!miniSource.contains("@ObservedObject var recorder: Recorder"))
        #expect(!componentsSource.contains("@ObservedObject var recorder: Recorder"))
        #expect(componentsSource.contains("let audioMeterSource: AudioMeterSource"))
        #expect(notchSource.contains("let audioMeterSource: AudioMeterSource"))
        #expect(miniSource.contains("let audioMeterSource: AudioMeterSource"))
    }

    @Test func recorderStatusDisplayKeepsOneVisualizerIdentityAcrossStartingAndRecording() throws {
        let componentsSource = try readProjectSource("VoiceInk/Views/Recorder/RecorderComponents.swift")
        let visualizerBranchCount = componentsSource
            .components(separatedBy: "AudioVisualizer(audioMeterSource: audioMeterSource")
            .count - 1

        #expect(componentsSource.contains("if currentState == .starting || currentState == .recording"))
        #expect(visualizerBranchCount == 1)
    }

}

private func eventually(
    timeout: TimeInterval = 0.5,
    condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}

@MainActor
private func makeModelContainer() throws -> ModelContainer {
    let schema = Schema([Transcription.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return container
}

private func makeCloudModel(name: String, provider: ModelProvider) -> CloudModel {
    CloudModel(
        name: name,
        displayName: name,
        description: "Test model",
        provider: provider,
        speed: 1,
        accuracy: 1,
        isMultilingual: true,
        supportsStreaming: true,
        supportedLanguages: ["en": "English"]
    )
}

private func makeWhisperTestModel() -> WhisperModel {
    WhisperModel(
        name: "ggml-test",
        displayName: "Whisper Test",
        size: "1 MB",
        supportedLanguages: ["en": "English"],
        description: "Test model",
        speed: 1,
        accuracy: 1,
        ramUsage: 1
    )
}

private func makeRealtimeConfiguration(
    model: any TranscriptionModel = makeCloudModel(name: "deepgram-live", provider: .deepgram),
    language: String = "en",
    isRealtimeEnabled: Bool = true,
    prompt: String? = "domain prompt"
) -> TranscriptionRuntimeConfiguration {
    TranscriptionRuntimeConfiguration(
        mode: nil,
        model: model,
        language: language,
        isRealtimeEnabled: isRealtimeEnabled,
        requestContext: TranscriptionRequestContext(language: language, prompt: prompt)
    )
}

private func readProjectSource(_ relativePath: String) throws -> String {
    let testFileURL = URL(fileURLWithPath: #filePath)
    let projectRootURL = testFileURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: projectRootURL.appendingPathComponent(relativePath),
        encoding: .utf8
    )
}

@MainActor
private final class FakeTranscriptionSession: TranscriptionSession {
    private(set) var cancelCallCount = 0
    var reusable = true
    var prepareCallback: RecordingAudioChunkHandler? = { _ in }

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> RecordingAudioChunkHandler? {
        prepareCallback
    }

    func canReusePreparedSession() -> Bool {
        reusable
    }

    func transcribe(audioURL: URL) async throws -> String {
        ""
    }

    func cancel() {
        cancelCallCount += 1
    }
}

private final class FakeStreamingProvider: StreamingTranscriptionProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _sentChunks: [Data] = []
    private var _sentChunkCountAtCommit: Int?
    private var _commitCallCount = 0
    private var _disconnectCallCount = 0
    private let commitEvents: [StreamingTranscriptionEvent]
    private let sendError: Error?
    private let connectError: Error?
    private let connectDelayNanoseconds: UInt64
    private let connectGate: FakeStreamingConnectGate?
    private let disconnectDelayNanoseconds: UInt64
    private let emitsFinalizedOnCommit: Bool
    private let eventContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init(
        commitEvent: StreamingTranscriptionEvent?,
        sendError: Error? = nil,
        connectError: Error? = nil,
        connectDelayNanoseconds: UInt64 = 0,
        connectGate: FakeStreamingConnectGate? = nil,
        disconnectDelayNanoseconds: UInt64 = 0,
        emitsFinalizedOnCommit: Bool = true
    ) {
        self.commitEvents = commitEvent.map { [$0] } ?? []
        self.sendError = sendError
        self.connectError = connectError
        self.connectDelayNanoseconds = connectDelayNanoseconds
        self.connectGate = connectGate
        self.disconnectDelayNanoseconds = disconnectDelayNanoseconds
        self.emitsFinalizedOnCommit = emitsFinalizedOnCommit
        let (stream, continuation) = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
        self.transcriptionEvents = stream
        self.eventContinuation = continuation
    }

    init(
        commitEvents: [StreamingTranscriptionEvent],
        sendError: Error? = nil,
        connectError: Error? = nil,
        connectDelayNanoseconds: UInt64 = 0,
        connectGate: FakeStreamingConnectGate? = nil,
        disconnectDelayNanoseconds: UInt64 = 0,
        emitsFinalizedOnCommit: Bool = true
    ) {
        self.commitEvents = commitEvents
        self.sendError = sendError
        self.connectError = connectError
        self.connectDelayNanoseconds = connectDelayNanoseconds
        self.connectGate = connectGate
        self.disconnectDelayNanoseconds = disconnectDelayNanoseconds
        self.emitsFinalizedOnCommit = emitsFinalizedOnCommit
        let (stream, continuation) = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
        self.transcriptionEvents = stream
        self.eventContinuation = continuation
    }

    var sentChunks: [Data] {
        withLock { _sentChunks }
    }

    var sentChunkCountAtCommit: Int? {
        withLock { _sentChunkCountAtCommit }
    }

    var commitCallCount: Int {
        withLock { _commitCallCount }
    }

    var disconnectCallCount: Int {
        withLock { _disconnectCallCount }
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        if let connectGate {
            await connectGate.wait()
        }
        if connectDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: connectDelayNanoseconds)
        }
        if let connectError {
            throw connectError
        }
        eventContinuation.yield(.sessionStarted)
    }

    func sendAudioChunk(_ data: Data) async throws {
        if let sendError {
            throw sendError
        }
        withLock { _sentChunks.append(data) }
    }

    func commit() async throws {
        withLock {
            _commitCallCount += 1
            _sentChunkCountAtCommit = _sentChunks.count
        }
        for commitEvent in commitEvents {
            eventContinuation.yield(commitEvent)
        }
        if emitsFinalizedOnCommit {
            eventContinuation.yield(.finalized)
        }
    }

    func emit(_ event: StreamingTranscriptionEvent) {
        eventContinuation.yield(event)
    }

    func disconnect() async {
        withLock { _disconnectCallCount += 1 }
        if disconnectDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: disconnectDelayNanoseconds)
        }
        eventContinuation.finish()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class FakeStreamingConnectGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isReleased = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isReleased {
                lock.unlock()
                continuation.resume()
            } else {
                precondition(waiter == nil)
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        isReleased = true
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume()
    }
}

private final class DelayedStartStreamingService: StreamingTranscriptionServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var _sentChunks: [Data] = []
    private var _startCallCount = 0
    private var _stopCallCount = 0
    private var _cancelCallCount = 0

    var startCallCount: Int {
        withLock { _startCallCount }
    }

    var stopCallCount: Int {
        withLock { _stopCallCount }
    }

    var cancelCallCount: Int {
        withLock { _cancelCallCount }
    }

    var sentChunks: [Data] {
        withLock { _sentChunks }
    }

    @MainActor
    var isActive: Bool { true }

    @MainActor
    func startStreaming(model: any TranscriptionModel, context: TranscriptionRequestContext) async throws {
        withLock { _startCallCount += 1 }
        await withCheckedContinuation { continuation in
            withLock { startContinuation = continuation }
        }
    }

    nonisolated func sendAudioChunk(_ data: Data) {
        withLock { _sentChunks.append(data) }
    }

    @MainActor
    func stopAndGetFinalText() async throws -> String {
        withLock { _stopCallCount += 1 }
        return "streaming transcript"
    }

    @MainActor
    func cancel() {
        withLock { _cancelCallCount += 1 }
        releaseStart()
    }

    func releaseStart() {
        let continuation = withLock { () -> CheckedContinuation<Void, Never>? in
            let continuation = startContinuation
            startContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class FakeStreamingService: StreamingTranscriptionServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var _sentChunks: [Data] = []
    private var _stopCallCount = 0
    private var _cancelCallCount = 0
    private let stopResult: Result<String, Error>

    init(stopResult: Result<String, Error>) {
        self.stopResult = stopResult
    }

    var sentChunks: [Data] {
        withLock { _sentChunks }
    }

    var stopCallCount: Int {
        withLock { _stopCallCount }
    }

    var cancelCallCount: Int {
        withLock { _cancelCallCount }
    }

    @MainActor
    var isActive: Bool { true }

    @MainActor
    func startStreaming(model: any TranscriptionModel, context: TranscriptionRequestContext) async throws {}

    nonisolated func sendAudioChunk(_ data: Data) {
        withLock { _sentChunks.append(data) }
    }

    @MainActor
    func stopAndGetFinalText() async throws -> String {
        withLock { _stopCallCount += 1 }
        return try stopResult.get()
    }

    @MainActor
    func cancel() {
        withLock { _cancelCallCount += 1 }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class FakeBatchTranscriptionService: TranscriptionService, @unchecked Sendable {
    private let lock = NSLock()
    private var _modelNames: [String] = []
    private let result: String

    init(result: String) {
        self.result = result
    }

    var transcribeCallCount: Int {
        withLock { _modelNames.count }
    }

    var modelNames: [String] {
        withLock { _modelNames }
    }

    func transcribe(
        audioURL: URL,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) async throws -> String {
        withLock { _modelNames.append(model.name) }
        return result
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
