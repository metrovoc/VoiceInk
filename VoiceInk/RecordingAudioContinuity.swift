import Atomics
import Foundation

/// PCM leaves the hardware queue and may be invoked by either the startup relay
/// or streaming consumer. Every handler must therefore be safe to transfer
/// across executors by construction.
typealias RecordingAudioChunkHandler = @Sendable (Data) -> Void

/// A per-recording, cross-layer integrity token.
///
/// Drop counters are updated directly from the Core Audio callback and are
/// therefore atomics only: no lock, allocation, executor hop, or user code is
/// reached from the realtime thread. Capture sealing happens after AUHAL has
/// stopped and both worker pipes have drained, so it may safely wake async
/// control-plane waiters.
final class RecordingAudioContinuity: @unchecked Sendable {
    let sessionID: UUID

    private let streamingDroppedChunks = ManagedAtomic<Int>(0)
    private let streamingDroppedBytes = ManagedAtomic<Int>(0)
    private let fileDroppedChunks = ManagedAtomic<Int>(0)
    private let fileDroppedBytes = ManagedAtomic<Int>(0)
    private let fileWriteErrors = ManagedAtomic<Int>(0)
    private let captureSealed = ManagedAtomic(false)
    /// Startup audio is provisionally eligible for realtime delivery. Once the
    /// final mode resolves to file-only, this is disabled so the callback pays
    /// no streaming counter cost for the rest of that recording.
    private let expectsStreaming = ManagedAtomic(true)

    private let sealLock = NSLock()
    private var sealWaiters: [CheckedContinuation<Void, Never>] = []

    init(sessionID: UUID = UUID(), expectsStreaming: Bool = true) {
        self.sessionID = sessionID
        self.expectsStreaming.store(expectsStreaming, ordering: .relaxed)
    }

    /// Realtime-safe. Called only to account for audio that can no longer reach
    /// the streaming provider.
    func recordStreamingDrop(byteCount: Int) {
        guard expectsStreaming.load(ordering: .relaxed) else { return }
        streamingDroppedChunks.wrappingIncrement(ordering: .relaxed)
        streamingDroppedBytes.wrappingIncrement(by: max(0, byteCount), ordering: .relaxed)
    }

    func enableStreamingTracking() {
        expectsStreaming.store(true, ordering: .releasing)
    }

    func disableStreamingTracking() {
        expectsStreaming.store(false, ordering: .releasing)
    }

    var isStreamingTrackingEnabled: Bool {
        expectsStreaming.load(ordering: .acquiring)
    }

    /// Realtime-safe. Called only to account for PCM that can no longer reach
    /// the recording file.
    func recordFileDrop(byteCount: Int) {
        fileDroppedChunks.wrappingIncrement(ordering: .relaxed)
        fileDroppedBytes.wrappingIncrement(by: max(0, byteCount), ordering: .relaxed)
    }

    /// Writer-queue only. Kept separate from dropped PCM because the file API
    /// can reject a write after the ring accepted the complete chunk.
    func recordFileWriteError() {
        fileWriteErrors.wrappingIncrement(ordering: .relaxed)
    }

    /// Realtime-safe accounting for conversion/render failures shared by both
    /// recording outputs.
    func recordCaptureDrop(byteCount: Int) {
        recordStreamingDrop(byteCount: byteCount)
        recordFileDrop(byteCount: byteCount)
    }

    func snapshot() -> RecordingAudioContinuitySnapshot {
        RecordingAudioContinuitySnapshot(
            sessionID: sessionID,
            streamingDroppedChunks: streamingDroppedChunks.load(ordering: .acquiring),
            streamingDroppedBytes: streamingDroppedBytes.load(ordering: .acquiring),
            fileDroppedChunks: fileDroppedChunks.load(ordering: .acquiring),
            fileDroppedBytes: fileDroppedBytes.load(ordering: .acquiring),
            fileWriteErrors: fileWriteErrors.load(ordering: .acquiring),
            isCaptureSealed: captureSealed.load(ordering: .acquiring)
        )
    }

    /// Called after AudioOutputUnitStop and worker-pipe drain, never from the
    /// Core Audio callback.
    func sealCapture() {
        sealLock.lock()
        guard !captureSealed.exchange(true, ordering: .acquiringAndReleasing) else {
            sealLock.unlock()
            return
        }
        let waiters = sealWaiters
        sealWaiters.removeAll(keepingCapacity: false)
        sealLock.unlock()

        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilCaptureSealed() async {
        if captureSealed.load(ordering: .acquiring) {
            return
        }

        await withCheckedContinuation { continuation in
            sealLock.lock()
            if captureSealed.load(ordering: .acquiring) {
                sealLock.unlock()
                continuation.resume()
            } else {
                sealWaiters.append(continuation)
                sealLock.unlock()
            }
        }
    }
}

struct RecordingAudioContinuitySnapshot: Sendable, Equatable {
    let sessionID: UUID
    let streamingDroppedChunks: Int
    let streamingDroppedBytes: Int
    let fileDroppedChunks: Int
    let fileDroppedBytes: Int
    let fileWriteErrors: Int
    let isCaptureSealed: Bool

    var hasStreamingDiscontinuity: Bool {
        streamingDroppedChunks > 0 || streamingDroppedBytes > 0
    }

    var hasFileDiscontinuity: Bool {
        fileDroppedChunks > 0 || fileDroppedBytes > 0 || fileWriteErrors > 0
    }
}

/// Thread-safe handoff used by the MainActor facade and generic-executor
/// finalization tasks. This lock is never touched by the audio callback.
final class RecordingAudioContinuityBinding: @unchecked Sendable {
    private let lock = NSLock()
    private var continuity: RecordingAudioContinuity?

    func bind(_ continuity: RecordingAudioContinuity?) {
        lock.lock()
        self.continuity = continuity
        lock.unlock()
    }

    func snapshot() -> RecordingAudioContinuity? {
        lock.lock()
        defer { lock.unlock() }
        return continuity
    }
}

enum RecordingAudioIntegrityError: LocalizedError, Equatable {
    case incompleteFile(droppedChunks: Int, droppedBytes: Int, writeErrors: Int)

    var errorDescription: String? {
        switch self {
        case .incompleteFile(let droppedChunks, let droppedBytes, let writeErrors):
            return "Recording audio is incomplete (dropped \(droppedChunks) chunks / \(droppedBytes) bytes, \(writeErrors) write errors)"
        }
    }
}
