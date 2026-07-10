import Foundation

/// Bounded control-event / latest-only partial mailbox. Providers never build
/// an unbounded backlog when the core is busy. Control events remain ordered
/// and lossless up to the hard safety limit; exceeding it produces one terminal
/// error so the complete recorded file can be used instead.
final class StreamingProviderEventRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var controls: [StreamingTranscriptionEvent?]
    private var controlHead = 0
    private var controlCount = 0
    private var latestPartial: StreamingTranscriptionEvent?
    private var waiter: CheckedContinuation<StreamingTranscriptionEvent?, Never>?
    private var isFinished = false

    init(maxBufferedControlEvents: Int = 4_096) {
        controls = Array(
            repeating: nil,
            count: max(1, maxBufferedControlEvents)
        )
    }

    lazy var stream: AsyncStream<StreamingTranscriptionEvent> = AsyncStream(
        unfolding: { [weak self] in
            await self?.next()
        },
        onCancel: { [weak self] in
            self?.finish()
        }
    )

    func yield(_ event: StreamingTranscriptionEvent) {
        var waiterToResume: CheckedContinuation<StreamingTranscriptionEvent?, Never>?
        var immediateEvent: StreamingTranscriptionEvent?

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }

        if let waiter {
            self.waiter = nil
            waiterToResume = waiter
            immediateEvent = event
        } else {
            switch event {
            case .partial:
                latestPartial = event
            case .committed, .finalized, .error, .sessionStarted:
                // A control event supersedes the mutable partial preceding it.
                latestPartial = nil
                if controlCount == controls.count {
                    // Committed text cannot be silently discarded. Replace the
                    // backlog with one terminal error so the session fails and
                    // uses its complete WAV fallback with constant memory.
                    clearControlsLocked()
                    insertControlLocked(
                        .error(
                            StreamingTranscriptionError.eventBacklogExceeded(
                                limit: controls.count
                            )
                        )
                    )
                    isFinished = true
                } else {
                    insertControlLocked(event)
                }
            }
        }
        lock.unlock()

        if let waiterToResume {
            waiterToResume.resume(returning: immediateEvent)
        }
    }

    func finish() {
        var waiterToResume: CheckedContinuation<StreamingTranscriptionEvent?, Never>?
        lock.lock()
        isFinished = true
        if bufferedEventLocked() == nil {
            waiterToResume = waiter
            waiter = nil
        }
        lock.unlock()
        waiterToResume?.resume(returning: nil)
    }

    private func next() async -> StreamingTranscriptionEvent? {
        await withCheckedContinuation { continuation in
            var immediate: StreamingTranscriptionEvent?
            var shouldResume = false

            lock.lock()
            if let event = takeBufferedEventLocked() {
                immediate = event
                shouldResume = true
            } else if isFinished {
                shouldResume = true
            } else {
                precondition(waiter == nil, "StreamingProviderEventRelay supports one consumer")
                waiter = continuation
            }
            lock.unlock()

            if shouldResume {
                continuation.resume(returning: immediate)
            }
        }
    }

    private func bufferedEventLocked() -> StreamingTranscriptionEvent? {
        if controlCount > 0 { return controls[controlHead] }
        return latestPartial
    }

    private func takeBufferedEventLocked() -> StreamingTranscriptionEvent? {
        if controlCount > 0 {
            let event = controls[controlHead]
            controls[controlHead] = nil
            controlHead = (controlHead + 1) % controls.count
            controlCount -= 1
            return event
        }
        defer { latestPartial = nil }
        return latestPartial
    }

    private func insertControlLocked(_ event: StreamingTranscriptionEvent) {
        let tail = (controlHead + controlCount) % controls.count
        controls[tail] = event
        controlCount += 1
    }

    private func clearControlsLocked() {
        for offset in 0..<controlCount {
            controls[(controlHead + offset) % controls.count] = nil
        }
        controlHead = 0
        controlCount = 0
    }
}

/// Events emitted by a streaming transcription provider
enum StreamingTranscriptionEvent: @unchecked Sendable {
    case sessionStarted
    /// Mutable text after the most recent committed delta. Providers must not
    /// prepend already committed session history.
    case partial(text: String)
    /// Immutable append delta. The core is the sole owner of committed history.
    case committed(text: String)
    /// Provider acknowledgement for the explicit end-of-audio command. This is
    /// deliberately separate from ordinary committed transcript segments.
    case finalized
    case error(Error)
}

/// Errors specific to streaming transcription
enum StreamingTranscriptionError: LocalizedError {
    case missingAPIKey
    case connectionFailed(String)
    case timeout
    case serverError(String)
    case notConnected
    case audioConversionFailed
    case emptyTranscript
    case audioDropped(chunks: Int, bytes: Int)
    case eventBacklogExceeded(limit: Int)
    case transcriptionWindowExceeded(maximumDuration: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return String(localized: "API key not configured for streaming transcription")
        case .connectionFailed(let message):
            return String(format: String(localized: "Streaming connection failed: %@"), message)
        case .timeout:
            return String(localized: "Streaming transcription timed out waiting for final result")
        case .serverError(let message):
            return String(format: String(localized: "Streaming server error: %@"), message)
        case .notConnected:
            return String(localized: "Not connected to streaming transcription service")
        case .audioConversionFailed:
            return String(localized: "Failed to convert audio chunk for streaming")
        case .emptyTranscript:
            return String(localized: "Streaming transcription returned no text")
        case .audioDropped(let chunks, let bytes):
            return String(format: String(localized: "Streaming audio dropped %d chunks (%d bytes)"), chunks, bytes)
        case .eventBacklogExceeded(let limit):
            return String(
                format: String(localized: "Streaming provider event backlog exceeded its %d-event safety limit"),
                limit
            )
        case .transcriptionWindowExceeded(let maximumDuration):
            return String(
                format: String(localized: "Realtime transcription could not preserve unconfirmed audio within its %.1f-second window"),
                maximumDuration
            )
        }
    }
}

/// Protocol for streaming transcription providers.
protocol StreamingTranscriptionProvider: AnyObject, Sendable {
    /// Connect to the streaming transcription endpoint
    func connect(model: any TranscriptionModel, language: String?) async throws

    /// Send a chunk of raw PCM audio data (16-bit, 16kHz, mono, little-endian)
    func sendAudioChunk(_ data: Data) async throws

    /// Commit the current audio buffer to finalize transcription
    func commit() async throws

    /// Disconnect from the streaming endpoint
    func disconnect() async

    /// Stream of transcription events from the provider
    var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent> { get }
}
