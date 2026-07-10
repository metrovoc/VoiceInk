import Foundation
import os

/// Immutable transcript state passed across the streaming/UI boundary.
///
/// `committedSegments` only grows, while `partial` is the provider's mutable
/// tail. Consumers can therefore update incrementally without repeatedly
/// diffing an ever-growing transcript string.
struct StreamingTranscriptSegment: Identifiable, Sendable, Equatable {
    let id: UInt64
    let text: String
}

struct StreamingTranscriptSnapshot: Sendable, Equatable {
    let revision: UInt64
    /// Lossless append delta since the preceding published snapshot. The UI
    /// owns stable history; partial-only frames carry an empty array.
    let appendedSegments: [StreamingTranscriptSegment]
    let partial: String?
}

/// Compatibility adapter for the deprecated full-string callback. It consumes
/// the same append-delta snapshots as the UI and only materializes history at
/// the coalesced publication cadence, never once per provider event.
private final class StreamingLegacyTranscriptAccumulator: @unchecked Sendable {
    private var committedText = ""
    private var partial: String?

    @MainActor
    func apply(_ snapshot: StreamingTranscriptSnapshot) -> String {
        for segment in snapshot.appendedSegments {
            if !committedText.isEmpty { committedText.append(" ") }
            committedText.append(segment.text)
        }
        partial = snapshot.partial
        guard let partial, !partial.isEmpty else { return committedText }
        return committedText.isEmpty ? partial : committedText + " " + partial
    }
}

enum StreamingAudioDiscontinuity: Sendable, Equatable {
    case audioDropped
}

/// A point-in-time view of the realtime audio transport.
///
/// All timestamps are monotonic (`systemUptime`) so they remain meaningful
/// across wall-clock changes. Queue ages intentionally include provider send
/// time: a slow socket must be visible as backpressure instead of silently
/// becoming latency.
struct StreamingMetricsSnapshot: Sendable, Equatable {
    let state: StreamingState
    let receivedChunks: Int
    let receivedBytes: Int
    let sentChunks: Int
    let sentBytes: Int
    let droppedChunks: Int
    let droppedBytes: Int
    let queueDepth: Int
    let oldestQueueAge: TimeInterval
    let maximumQueueDepth: Int
    let maximumQueueAge: TimeInterval
    let queueAgeBudgetExceeded: Bool
    let audioDiscontinuity: StreamingAudioDiscontinuity?
    let stopRequestedAt: TimeInterval?
    let commitDispatchedAt: TimeInterval?
    let finalReceivedAt: TimeInterval?

    var stopToCommitDispatch: TimeInterval? {
        guard let stopRequestedAt, let commitDispatchedAt else { return nil }
        return max(0, commitDispatchedAt - stopRequestedAt)
    }
}

struct QueuedAudioChunk: Sendable {
    let data: Data
    let enqueuedAt: TimeInterval
}

/// A bounded, single-consumer queue designed for the Core Audio callback.
/// Enqueue is O(1), never awaits, and never performs `removeFirst` copies.
final class StreamingAudioQueue: @unchecked Sendable {
    enum EnqueueResult {
        case enqueued(depth: Int, oldestAge: TimeInterval)
        case enqueuedDroppingOldest(
            droppedBytes: Int,
            droppedAge: TimeInterval,
            depth: Int,
            oldestAge: TimeInterval
        )
        case terminated(marksAudioDiscontinuity: Bool)
    }

    enum DequeueResult {
        case audio(QueuedAudioChunk)
        case commit
        case cancelled
    }

    struct Snapshot {
        let depth: Int
        let oldestAge: TimeInterval
    }

    struct DiscardedAudio {
        let chunks: Int
        let bytes: Int
        let maximumAge: TimeInterval
    }

    private enum TerminalMode {
        case open
        case commit
        case cancelled
    }

    private let lock = NSLock()
    private var storage: [QueuedAudioChunk?]
    private var head = 0
    private var count = 0
    private var inFlight: QueuedAudioChunk?
    private var terminalMode: TerminalMode = .open
    private var terminatedIngressMarksAudioDiscontinuity = false
    private var waiter: CheckedContinuation<DequeueResult, Never>?
    /// Provider connection time is external latency. Audio captured before the
    /// transport is ready remains lossless startup backlog, but its local queue
    /// age budget begins only when that backlog can actually be drained.
    private var transportReadyAt: TimeInterval?

    init(capacity: Int) {
        storage = Array(repeating: nil, count: max(1, capacity))
    }

    func enqueue(_ data: Data, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> EnqueueResult {
        let chunk = QueuedAudioChunk(data: data, enqueuedAt: now)
        var waiterToResume: CheckedContinuation<DequeueResult, Never>?
        var result: EnqueueResult

        lock.lock()
        guard terminalMode == .open else {
            let marksAudioDiscontinuity = terminatedIngressMarksAudioDiscontinuity
            lock.unlock()
            return .terminated(
                marksAudioDiscontinuity: marksAudioDiscontinuity
            )
        }

        if let waiter {
            self.waiter = nil
            precondition(inFlight == nil, "StreamingAudioQueue already has in-flight audio")
            inFlight = chunk
            waiterToResume = waiter
            result = .enqueued(depth: 0, oldestAge: 0)
        } else if count < storage.count {
            insertAtTail(chunk)
            result = .enqueued(depth: count, oldestAge: oldestAgeLocked(now: now))
        } else {
            let dropped = removeHeadLocked()
            insertAtTail(chunk)
            result = .enqueuedDroppingOldest(
                droppedBytes: dropped?.data.count ?? 0,
                droppedAge: dropped.map { queueAgeLocked(of: $0, now: now) } ?? 0,
                depth: count,
                oldestAge: oldestAgeLocked(now: now)
            )
        }
        lock.unlock()

        waiterToResume?.resume(returning: .audio(chunk))
        return result
    }

    func next() async -> DequeueResult {
        await withCheckedContinuation { continuation in
            var immediate: DequeueResult?

            lock.lock()
            if let chunk = removeHeadLocked() {
                precondition(inFlight == nil, "StreamingAudioQueue already has in-flight audio")
                inFlight = chunk
                immediate = .audio(chunk)
            } else {
                switch terminalMode {
                case .open:
                    precondition(waiter == nil, "StreamingAudioQueue supports one consumer")
                    waiter = continuation
                case .commit:
                    immediate = .commit
                    terminalMode = .cancelled
                case .cancelled:
                    immediate = .cancelled
                }
            }
            lock.unlock()

            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
    }

    func markTransportReady(
        at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        lock.lock()
        if transportReadyAt == nil {
            transportReadyAt = timestamp
        }
        lock.unlock()
    }

    func queueAge(
        of chunk: QueuedAudioChunk,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval {
        lock.lock()
        let age = queueAgeLocked(of: chunk, now: now)
        lock.unlock()
        return age
    }

    /// Completes the single provider send. A false result means cancellation
    /// already claimed the in-flight chunk as discarded, so telemetry must not
    /// count it again as sent.
    func completeInFlight() -> Bool {
        lock.lock()
        let completed = inFlight != nil
        inFlight = nil
        lock.unlock()
        return completed
    }

    /// Seals audio ingress and places a commit command after all buffered audio.
    /// The single consumer therefore provides ordering without a second drain
    /// task or a provider-level lock.
    func requestCommit() {
        var waiterToResume: CheckedContinuation<DequeueResult, Never>?

        lock.lock()
        guard terminalMode == .open else {
            lock.unlock()
            return
        }
        terminalMode = .commit
        terminatedIngressMarksAudioDiscontinuity = true
        if count == 0 {
            waiterToResume = waiter
            waiter = nil
            if waiterToResume != nil {
                terminalMode = .cancelled
            }
        }
        lock.unlock()

        waiterToResume?.resume(returning: .commit)
    }

    /// Cancels immediately and discards buffered audio. This is intentionally
    /// distinct from requestCommit(): cancellation can never accidentally send
    /// a final provider command. Queue cancellation and discard telemetry share
    /// one entry point so every chunk has exactly one terminal disposition.
    @discardableResult
    func cancel(
        recordingDiscardedWith telemetry: StreamingTelemetry,
        marksAudioDiscontinuity: Bool,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> DiscardedAudio {
        var waiterToResume: CheckedContinuation<DequeueResult, Never>?

        lock.lock()
        terminatedIngressMarksAudioDiscontinuity =
            terminatedIngressMarksAudioDiscontinuity || marksAudioDiscontinuity
        terminalMode = .cancelled
        let discarded = clearLocked(now: now)
        waiterToResume = waiter
        waiter = nil
        lock.unlock()

        telemetry.recordDiscarded(
            chunkCount: discarded.chunks,
            byteCount: discarded.bytes,
            maximumAge: discarded.maximumAge,
            marksAudioDiscontinuity: marksAudioDiscontinuity
        )
        waiterToResume?.resume(returning: .cancelled)
        return discarded
    }

    func snapshot(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Snapshot {
        lock.lock()
        let snapshot = Snapshot(depth: count, oldestAge: oldestAgeLocked(now: now))
        lock.unlock()
        return snapshot
    }

    private func insertAtTail(_ chunk: QueuedAudioChunk) {
        let tail = (head + count) % storage.count
        storage[tail] = chunk
        count += 1
    }

    private func removeHeadLocked() -> QueuedAudioChunk? {
        guard count > 0 else { return nil }
        let chunk = storage[head]
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        return chunk
    }

    private func clearLocked(now: TimeInterval) -> DiscardedAudio {
        var chunks = 0
        var bytes = 0
        var maximumAge: TimeInterval = 0
        if let inFlight {
            chunks += 1
            bytes += inFlight.data.count
            maximumAge = max(maximumAge, queueAgeLocked(of: inFlight, now: now))
            self.inFlight = nil
        }
        while count > 0 {
            guard let chunk = removeHeadLocked() else { break }
            chunks += 1
            bytes += chunk.data.count
            maximumAge = max(maximumAge, queueAgeLocked(of: chunk, now: now))
        }
        return DiscardedAudio(
            chunks: chunks,
            bytes: bytes,
            maximumAge: maximumAge
        )
    }

    private func oldestAgeLocked(now: TimeInterval) -> TimeInterval {
        guard count > 0, let oldest = storage[head] else { return 0 }
        return queueAgeLocked(of: oldest, now: now)
    }

    private func queueAgeLocked(
        of chunk: QueuedAudioChunk,
        now: TimeInterval
    ) -> TimeInterval {
        guard let transportReadyAt else { return 0 }
        return max(0, now - max(chunk.enqueuedAt, transportReadyAt))
    }
}

/// Lock-backed telemetry shared by the realtime callback, streaming actor, and
/// diagnostics. Reading metrics never requires an actor hop.
final class StreamingTelemetry: @unchecked Sendable {
    private let maximumPermittedQueueAge: TimeInterval
    private let lock = NSLock()
    private var state: StreamingState = .idle
    private var receivedChunks = 0
    private var receivedBytes = 0
    private var sentChunks = 0
    private var sentBytes = 0
    private var droppedChunks = 0
    private var droppedBytes = 0
    private var maximumQueueDepth = 0
    private var maximumQueueAge: TimeInterval = 0
    private var queueAgeBudgetExceeded = false
    private var audioDiscontinuity: StreamingAudioDiscontinuity?
    private var stopRequestedAt: TimeInterval?
    private var commitDispatchedAt: TimeInterval?
    private var finalReceivedAt: TimeInterval?

    init(
        maximumPermittedQueueAge: TimeInterval = RealtimePerformanceBudget.maximumStreamingQueueAge
    ) {
        self.maximumPermittedQueueAge = maximumPermittedQueueAge
    }

    func setState(_ state: StreamingState) {
        lock.lock()
        self.state = state
        lock.unlock()
    }

    func recordEnqueue(byteCount: Int, depth: Int, oldestAge: TimeInterval) {
        lock.lock()
        receivedChunks += 1
        receivedBytes += byteCount
        maximumQueueDepth = max(maximumQueueDepth, depth)
        maximumQueueAge = max(maximumQueueAge, oldestAge)
        if oldestAge > maximumPermittedQueueAge {
            queueAgeBudgetExceeded = true
        }
        lock.unlock()
    }

    func recordDropped(byteCount: Int, age: TimeInterval) {
        recordDiscarded(
            chunkCount: 1,
            byteCount: byteCount,
            maximumAge: age,
            marksAudioDiscontinuity: true
        )
    }

    func recordDiscarded(
        chunkCount: Int,
        byteCount: Int,
        maximumAge: TimeInterval,
        marksAudioDiscontinuity: Bool
    ) {
        guard chunkCount > 0 else { return }
        lock.lock()
        droppedChunks += chunkCount
        droppedBytes += byteCount
        maximumQueueAge = max(maximumQueueAge, maximumAge)
        if marksAudioDiscontinuity, audioDiscontinuity == nil {
            audioDiscontinuity = .audioDropped
        }
        lock.unlock()
    }

    func recordSent(byteCount: Int, queueAge: TimeInterval) {
        lock.lock()
        sentChunks += 1
        sentBytes += byteCount
        maximumQueueAge = max(maximumQueueAge, queueAge)
        if queueAge > maximumPermittedQueueAge {
            queueAgeBudgetExceeded = true
        }
        lock.unlock()
    }

    func markStopRequested(at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        if stopRequestedAt == nil {
            stopRequestedAt = timestamp
        }
        lock.unlock()
    }

    func markCommitDispatched(at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        if commitDispatchedAt == nil {
            commitDispatchedAt = timestamp
        }
        lock.unlock()
    }

    func markFinalReceived(at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        if finalReceivedAt == nil {
            finalReceivedAt = timestamp
        }
        lock.unlock()
    }

    func snapshot(queue: StreamingAudioQueue.Snapshot) -> StreamingMetricsSnapshot {
        lock.lock()
        let snapshot = StreamingMetricsSnapshot(
            state: state,
            receivedChunks: receivedChunks,
            receivedBytes: receivedBytes,
            sentChunks: sentChunks,
            sentBytes: sentBytes,
            droppedChunks: droppedChunks,
            droppedBytes: droppedBytes,
            queueDepth: queue.depth,
            oldestQueueAge: queue.oldestAge,
            maximumQueueDepth: maximumQueueDepth,
            maximumQueueAge: max(maximumQueueAge, queue.oldestAge),
            queueAgeBudgetExceeded: queueAgeBudgetExceeded || queue.oldestAge > maximumPermittedQueueAge,
            audioDiscontinuity: audioDiscontinuity,
            stopRequestedAt: stopRequestedAt,
            commitDispatchedAt: commitDispatchedAt,
            finalReceivedAt: finalReceivedAt
        )
        lock.unlock()
        return snapshot
    }
}

private final class RealtimeTranscriptionActivity: @unchecked Sendable {
    private var token: NSObjectProtocol?

    func begin(reason: String) {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: reason
        )
    }

    func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }
}

private final class StreamingTimeoutRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func install(
        operationTask: Task<Void, Never>,
        timeoutTask: Task<Void, Never>
    ) {
        lock.lock()
        if resolved {
            lock.unlock()
            operationTask.cancel()
            timeoutTask.cancel()
        } else {
            self.operationTask = operationTask
            self.timeoutTask = timeoutTask
            lock.unlock()
        }
    }

    @discardableResult
    func resolve(
        _ continuation: CheckedContinuation<Value, Error>,
        with result: Result<Value, Error>
    ) -> Bool {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return false
        }
        resolved = true
        let operationTask = operationTask
        let timeoutTask = timeoutTask
        self.operationTask = nil
        self.timeoutTask = nil
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        }
        return true
    }
}

/// The sole owner of a provider's realtime lifecycle. No method or task in this
/// actor is MainActor-isolated. UI delivery is the only explicit hop to the main
/// actor, after transcript state has already been reduced to an immutable value.
actor StreamingTranscriptionCore {
    private enum SendLoopCompletion {
        case committed
        case cancelled
        case failed(Error)
    }

    private let logger = Logger(
        subsystem: AppIdentity.loggerSubsystem,
        category: "StreamingTranscriptionCore"
    )
    private let audioQueue: StreamingAudioQueue
    private let telemetry: StreamingTelemetry
    private let partialCoalescer: StreamingPartialEventCoalescer
    private let drainTimeoutNanoseconds: UInt64
    private let finalCommitTimeoutNanoseconds: UInt64
    private let disconnectTimeoutNanoseconds: UInt64
    private let activity = RealtimeTranscriptionActivity()

    private var state: StreamingState = .idle
    private var provider: (any StreamingTranscriptionProvider)?
    private var sendTask: Task<Void, Never>?
    private var sendCompletionContinuation: AsyncStream<SendLoopCompletion>.Continuation?
    private var sendCompletionStream: AsyncStream<SendLoopCompletion>?
    private var eventConsumerTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private var finalSignalContinuation: AsyncStream<Void>.Continuation?
    private var finalizationTask: Task<String, Error>?
    private var connectionWaiters: [CheckedContinuation<Void, Error>] = []
    private var awaitingExplicitCommitAck = false
    private var failure: Error?
    private var committedSegments: [StreamingTranscriptSegment] = []
    private var revision: UInt64 = 0
    private var nextSegmentID: UInt64 = 0
    private var firstPartialReceived = false
    private var firstCommitLogged = false
    private var performanceTrace: RealtimePerformanceTrace?
    private var onPartialTranscript: (@MainActor @Sendable (String) -> Void)?
    private var onTranscriptSnapshot: (@MainActor @Sendable (StreamingTranscriptSnapshot) -> Void)?
    private let legacyTranscriptAccumulator = StreamingLegacyTranscriptAccumulator()

    deinit {
        sendTask?.cancel()
        eventConsumerTask?.cancel()
        partialCoalescer.cancel()
        audioQueue.cancel(
            recordingDiscardedWith: telemetry,
            marksAudioDiscontinuity: false
        )
        activity.end()
    }

    init(
        audioQueue: StreamingAudioQueue,
        telemetry: StreamingTelemetry,
        partialCoalescer: StreamingPartialEventCoalescer,
        drainTimeoutNanoseconds: UInt64,
        finalCommitTimeoutNanoseconds: UInt64,
        disconnectTimeoutNanoseconds: UInt64,
        onPartialTranscript: (@MainActor @Sendable (String) -> Void)?,
        onTranscriptSnapshot: (@MainActor @Sendable (StreamingTranscriptSnapshot) -> Void)?
    ) {
        self.audioQueue = audioQueue
        self.telemetry = telemetry
        self.partialCoalescer = partialCoalescer
        self.drainTimeoutNanoseconds = drainTimeoutNanoseconds
        self.finalCommitTimeoutNanoseconds = finalCommitTimeoutNanoseconds
        self.disconnectTimeoutNanoseconds = disconnectTimeoutNanoseconds
        self.onPartialTranscript = onPartialTranscript
        self.onTranscriptSnapshot = onTranscriptSnapshot
    }

    func start(
        provider: any StreamingTranscriptionProvider,
        model: any TranscriptionModel,
        language: String?,
        performanceTrace: RealtimePerformanceTrace?
    ) async throws {
        guard state == .idle else {
            if state == .cancelled { throw CancellationError() }
            throw StreamingTranscriptionError.connectionFailed("Streaming session already started")
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        self.performanceTrace = performanceTrace
        self.provider = provider
        self.failure = nil
        self.committedSegments = []
        self.revision = 0
        self.nextSegmentID = 0
        self.firstPartialReceived = false
        self.firstCommitLogged = false
        partialCoalescer.cancel()
        transition(to: .connecting)
        activity.begin(reason: "Realtime transcription")
        startEventConsumer(provider: provider)

        do {
            performanceTrace?.mark(.providerConnectStarted)
            try await provider.connect(model: model, language: language)
        } catch is CancellationError where state == .cancelled {
            resolveConnectionWaiters(with: .failure(CancellationError()))
            await cleanup(terminalState: .cancelled)
            throw CancellationError()
        } catch {
            resolveConnectionWaiters(with: .failure(error))
            await finishAfterFailure(error)
            throw error
        }

        guard state == .connecting else {
            if let failure {
                await finishAfterFailure(failure)
                throw failure
            }
            resolveConnectionWaiters(with: .failure(CancellationError()))
            await cleanup(terminalState: .cancelled)
            throw CancellationError()
        }

        audioQueue.markTransportReady()
        transition(to: .streaming)
        startSendLoop(provider: provider)
        resolveConnectionWaiters(with: .success(()))
        performanceTrace?.mark(.streamingConnected)
        logger.notice(
            "Streaming connected model=\(model.displayName, privacy: .public) elapsed=\(ProcessInfo.processInfo.systemUptime - startedAt, format: .fixed(precision: 3), privacy: .public)s"
        )
    }

    func updatePerformanceTrace(_ trace: RealtimePerformanceTrace?) {
        if let trace {
            performanceTrace = trace
        }
    }

    func stopAndGetFinalText() async throws -> String {
        if let finalizationTask {
            return try await finalizationTask.value
        }

        let task = Task { [weak self] () throws -> String in
            guard let self else { throw CancellationError() }
            return try await self.performFinalization()
        }
        finalizationTask = task
        return try await task.value
    }

    func cancel() async {
        guard state != .done && state != .cancelled else { return }
        let wasConnecting = state == .connecting
        transition(to: .cancelled)
        resolveConnectionWaiters(with: .failure(CancellationError()))
        finalizationTask?.cancel()
        audioQueue.cancel(
            recordingDiscardedWith: telemetry,
            marksAudioDiscontinuity: false
        )
        if wasConnecting {
            // `start()` still exclusively owns provider.connect(). It will run
            // cleanup after connect returns/throws; disconnecting here would
            // overlap provider I/O.
            partialCoalescer.cancel()
            eventConsumerTask?.cancel()
            logger.notice("Streaming cancellation requested while connecting")
            return
        }
        await cleanup(terminalState: .cancelled)
        logger.notice("Streaming cancelled")
    }

    private func performFinalization() async throws -> String {
        if state == .connecting {
            try await waitForConnection()
        }
        if let failure {
            await finishAfterFailure(failure)
            throw failure
        }
        guard state == .streaming, provider != nil else {
            if state == .cancelled { throw CancellationError() }
            throw StreamingTranscriptionError.notConnected
        }

        let stopTimestamp = ProcessInfo.processInfo.systemUptime
        telemetry.markStopRequested(at: stopTimestamp)
        let metricsBeforeStop = telemetry.snapshot(queue: audioQueue.snapshot(now: stopTimestamp))
        logger.notice(
            "Streaming stop requested receivedChunks=\(metricsBeforeStop.receivedChunks, privacy: .public) sentChunks=\(metricsBeforeStop.sentChunks, privacy: .public) queueDepth=\(metricsBeforeStop.queueDepth, privacy: .public) oldestQueueAge=\(metricsBeforeStop.oldestQueueAge, format: .fixed(precision: 3), privacy: .public)s droppedChunks=\(metricsBeforeStop.droppedChunks, privacy: .public)"
        )

        let (finalStream, finalContinuation) = AsyncStream.makeStream(of: Void.self)
        finalSignalContinuation = finalContinuation

        // A discontinuous realtime stream can never be accepted as the final
        // result. Fail before provider commit when the condition is already
        // known; `throwIfAudioDiscontinuous` runs again after the send loop to
        // catch a race with the last in-flight chunks.
        do {
            try throwIfAudioDiscontinuous()
        } catch {
            await finishAfterFailure(error)
            throw error
        }
        audioQueue.requestCommit()

        do {
            let sendCompletion = try await waitForSendLoopCompletion()
            if let failure {
                throw failure
            }
            switch sendCompletion {
            case .committed:
                break
            case .cancelled:
                throw CancellationError()
            case .failed(let error):
                throw error
            }
            let drainedMetrics = telemetry.snapshot(queue: audioQueue.snapshot())
            if drainedMetrics.queueAgeBudgetExceeded {
                logger.warning(
                    "Streaming queue latency budget exceeded maxAge=\(drainedMetrics.maximumQueueAge, format: .fixed(precision: 3), privacy: .public)s; audio remained continuous"
                )
            }
            try throwIfAudioDiscontinuous()
            try await waitForFinalCommit(signalStream: finalStream)
            if let failure { throw failure }
        } catch {
            await finishAfterFailure(error)
            throw error
        }

        let finalText = committedSegments.map(\.text).joined(separator: " ")
        let completedAt = ProcessInfo.processInfo.systemUptime
        transition(to: .done)
        logger.notice(
            "Streaming stop completed elapsed=\(completedAt - stopTimestamp, format: .fixed(precision: 3), privacy: .public)s finalChars=\(finalText.count, privacy: .public)"
        )
        await cleanup(terminalState: .done)
        return finalText
    }

    private func startSendLoop(provider: any StreamingTranscriptionProvider) {
        let audioQueue = audioQueue
        let telemetry = telemetry
        let (stream, continuation) = AsyncStream.makeStream(of: SendLoopCompletion.self)
        sendCompletionStream = stream
        sendCompletionContinuation = continuation

        sendTask = Task.detached(priority: .userInitiated) { [weak self] in
            let completion: SendLoopCompletion
            do {
                sendLoop: while true {
                    try Task.checkCancellation()
                    switch await audioQueue.next() {
                    case .audio(let chunk):
                        do {
                            try Task.checkCancellation()
                            try await provider.sendAudioChunk(chunk.data)
                            let queueAge = audioQueue.queueAge(
                                of: chunk,
                                now: ProcessInfo.processInfo.systemUptime
                            )
                            if audioQueue.completeInFlight() {
                                telemetry.recordSent(
                                    byteCount: chunk.data.count,
                                    queueAge: queueAge
                                )
                            }
                        } catch {
                            audioQueue.cancel(
                                recordingDiscardedWith: telemetry,
                                marksAudioDiscontinuity: false
                            )
                            throw error
                        }
                    case .commit:
                        let commitTimestamp = ProcessInfo.processInfo.systemUptime
                        guard await self?.beginExplicitCommit(at: commitTimestamp) == true else {
                            completion = .cancelled
                            break sendLoop
                        }
                        try Task.checkCancellation()
                        try await provider.commit()
                        completion = .committed
                        break sendLoop
                    case .cancelled:
                        completion = .cancelled
                        break sendLoop
                    }
                }
            } catch is CancellationError {
                completion = .cancelled
            } catch {
                completion = .failed(error)
                await self?.recordFailure(error)
            }

            continuation.yield(completion)
            continuation.finish()
        }
    }

    private func startEventConsumer(provider: any StreamingTranscriptionProvider) {
        let events = provider.transcriptionEvents
        eventConsumerTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.receive(event)
            }
        }
    }

    private func receive(_ event: StreamingTranscriptionEvent) {
        switch event {
        case .sessionStarted:
            break

        case .partial(let text):
            guard state == .streaming else { return }
            if !firstPartialReceived {
                firstPartialReceived = true
                performanceTrace?.mark(.firstPartialReceived)
                logger.notice("Streaming first partial event chars=\(text.count, privacy: .public)")
            }
            revision &+= 1
            let normalizedPartial = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let snapshot = StreamingTranscriptSnapshot(
                revision: revision,
                appendedSegments: [],
                partial: normalizedPartial.isEmpty ? nil : normalizedPartial
            )
            scheduleDelivery(snapshot: snapshot)

        case .committed(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !firstCommitLogged {
                firstCommitLogged = true
                logger.notice("Streaming first committed event chars=\(trimmed.count, privacy: .public)")
            }
            var appendedSegments: [StreamingTranscriptSegment] = []
            if !trimmed.isEmpty {
                nextSegmentID &+= 1
                let segment = StreamingTranscriptSegment(id: nextSegmentID, text: trimmed)
                committedSegments.append(segment)
                appendedSegments.append(segment)
            }
            revision &+= 1

            if state == .streaming {
                let snapshot = StreamingTranscriptSnapshot(
                    revision: revision,
                    appendedSegments: appendedSegments,
                    partial: nil
                )
                scheduleDelivery(snapshot: snapshot)
            }

        case .finalized:
            guard state == .committing, awaitingExplicitCommitAck else { return }
            awaitingExplicitCommitAck = false
            let timestamp = ProcessInfo.processInfo.systemUptime
            telemetry.markFinalReceived(at: timestamp)
            performanceTrace?.mark(.finalReceived, at: timestamp)
            finalSignalContinuation?.yield()

        case .error(let error):
            recordFailure(error)
            audioQueue.cancel(
                recordingDiscardedWith: telemetry,
                marksAudioDiscontinuity: false
            )
            sendTask?.cancel()
            if state == .connecting {
                resolveConnectionWaiters(with: .failure(error))
            }
            if state == .connecting || state == .streaming || state == .committing {
                transition(to: .failed)
            }
            finalSignalContinuation?.yield()
            finalSignalContinuation?.finish()
            logger.error("Streaming event error: \(error, privacy: .public)")
        }
    }

    private func scheduleDelivery(snapshot: StreamingTranscriptSnapshot) {
        let snapshotHandler = onTranscriptSnapshot
        let legacyHandler = onPartialTranscript
        let legacyAccumulator = legacyTranscriptAccumulator
        let trace = performanceTrace
        partialCoalescer.submit(snapshot: snapshot, legacyText: "") { snapshot, _ in
            if snapshot.partial != nil {
                trace?.mark(.firstPartialPublished)
            }
            snapshotHandler?(snapshot)
            if let legacyHandler {
                legacyHandler(legacyAccumulator.apply(snapshot))
            }
        }
    }

    private func recordFailure(_ error: Error) {
        if failure == nil {
            failure = error
        }
    }

    /// Establishes the explicit-commit acknowledgement generation before the
    /// provider call. Ordinary committed segments observed while draining are
    /// still handled in `.streaming` and cannot satisfy the final waiter.
    private func beginExplicitCommit(at timestamp: TimeInterval) -> Bool {
        guard state == .streaming, failure == nil else { return false }
        awaitingExplicitCommitAck = true
        transition(to: .committing)
        telemetry.markCommitDispatched(at: timestamp)
        performanceTrace?.mark(.commitRequested, at: timestamp)
        return true
    }

    private func waitForConnection() async throws {
        if state == .streaming { return }
        guard state == .connecting else {
            if let failure { throw failure }
            if state == .cancelled { throw CancellationError() }
            throw StreamingTranscriptionError.notConnected
        }

        try await withCheckedThrowingContinuation { continuation in
            connectionWaiters.append(continuation)
        }
    }

    private func resolveConnectionWaiters(with result: Result<Void, Error>) {
        let waiters = connectionWaiters
        connectionWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            switch result {
            case .success:
                waiter.resume()
            case .failure(let error):
                waiter.resume(throwing: error)
            }
        }
    }

    private func waitForSendLoopCompletion() async throws -> SendLoopCompletion {
        guard let stream = sendCompletionStream else {
            throw StreamingTranscriptionError.notConnected
        }
        return try await Self.withTimeout(nanoseconds: drainTimeoutNanoseconds) {
            for await completion in stream {
                return completion
            }
            return .cancelled
        }
    }

    private func waitForFinalCommit(signalStream: AsyncStream<Void>) async throws {
        let received = try await Self.withTimeout(
            nanoseconds: finalCommitTimeoutNanoseconds
        ) {
            for await _ in signalStream {
                return true
            }
            return false
        }

        finalSignalContinuation?.finish()
        finalSignalContinuation = nil
        guard received else {
            logger.warning("No final commit acknowledgement received from streaming provider")
            throw StreamingTranscriptionError.timeout
        }
    }

    private nonisolated static func withTimeout<Value: Sendable>(
        nanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let race = StreamingTimeoutRace<Value>()
            let operationTask = Task.detached(priority: .userInitiated) {
                do {
                    let value = try await operation()
                    race.resolve(continuation, with: .success(value))
                } catch {
                    race.resolve(continuation, with: .failure(error))
                }
            }
            let timeoutTask = Task.detached(priority: .userInitiated) {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                race.resolve(
                    continuation,
                    with: .failure(StreamingTranscriptionError.timeout)
                )
            }
            race.install(operationTask: operationTask, timeoutTask: timeoutTask)
        }
    }

    private func throwIfAudioDiscontinuous() throws {
        let snapshot = telemetry.snapshot(queue: audioQueue.snapshot())
        switch snapshot.audioDiscontinuity {
        case .audioDropped:
            logger.error(
                "Streaming audio dropped chunks=\(snapshot.droppedChunks, privacy: .public) bytes=\(snapshot.droppedBytes, privacy: .public)"
            )
            throw StreamingTranscriptionError.audioDropped(
                chunks: snapshot.droppedChunks,
                bytes: snapshot.droppedBytes
            )
        case nil:
            return
        }
    }

    private func finishAfterFailure(_ error: Error) async {
        recordFailure(error)
        transition(to: .failed)
        await cleanup(terminalState: .failed)
    }

    private func cleanup(terminalState: StreamingState) async {
        partialCoalescer.cancel()
        audioQueue.cancel(
            recordingDiscardedWith: telemetry,
            marksAudioDiscontinuity: false
        )
        let sendTaskToJoin = sendTask
        sendTaskToJoin?.cancel()
        sendTask = nil
        sendCompletionContinuation?.finish()
        sendCompletionContinuation = nil
        sendCompletionStream = nil
        let eventTaskToJoin = eventConsumerTask
        eventTaskToJoin?.cancel()
        eventConsumerTask = nil
        finalSignalContinuation?.finish()
        finalSignalContinuation = nil
        awaitingExplicitCommitAck = false
        if !connectionWaiters.isEmpty {
            let error: Error = terminalState == .cancelled
                ? CancellationError()
                : (failure ?? StreamingTranscriptionError.notConnected)
            resolveConnectionWaiters(with: .failure(error))
        }

        let providerToDisconnect = provider
        provider = nil
        if let providerToDisconnect {
            scheduleDisconnect(
                providerToDisconnect,
                afterSendTask: sendTaskToJoin,
                eventTask: eventTaskToJoin
            )
        }

        activity.end()
        onPartialTranscript = nil
        onTranscriptSnapshot = nil
        transition(to: terminalState)
    }

    /// Disconnect is retained and timeout-monitored, but intentionally not on
    /// the final result's critical path. Queue/event ownership has already been
    /// sealed before this task is created, so returning final text cannot race
    /// with further provider events. A non-cooperative provider may outlive the
    /// timeout warning; it still self-retains until its disconnect returns.
    private func scheduleDisconnect(
        _ provider: any StreamingTranscriptionProvider,
        afterSendTask sendTask: Task<Void, Never>?,
        eventTask: Task<Void, Never>?
    ) {
        let timeout = disconnectTimeoutNanoseconds
        let logger = logger
        teardownTask?.cancel()
        teardownTask = Task.detached(priority: .utility) {
            // Provider protocol methods have one owner. Cancellation first
            // seals new work; disconnect starts only after any in-flight
            // send/commit and the event consumer have quiesced.
            await sendTask?.value
            await eventTask?.value

            do {
                try await Self.withTimeout(nanoseconds: timeout) {
                    await provider.disconnect()
                }
            } catch {
                // `withTimeout` races unstructured tasks and never joins an
                // uncooperative provider. The provider remains self-retained by
                // its operation task until it eventually returns, while this
                // timeout is observable at the configured wall-clock bound.
                logger.warning("Timed out while disconnecting streaming provider")
            }
        }
    }

    private func transition(to state: StreamingState) {
        self.state = state
        telemetry.setState(state)
    }
}
