import Foundation

@MainActor
final class RecordingAudioTaskCoordinator {
    // Recorder.deinit is nonisolated even though Recorder itself is MainActor.
    // These handles are only mutated on MainActor while the owner is alive;
    // the nonisolated deinit path can only cancel them after the owner becomes
    // unreachable, so there is no concurrent writer.
    nonisolated(unsafe) private var muteTask: Task<Void, Never>?
    nonisolated(unsafe) private var pauseTask: Task<Void, Never>?
    nonisolated(unsafe) private var restorationTask: Task<Void, Never>?

    func scheduleMute(
        afterDelayNanoseconds delay: UInt64,
        operation: @escaping @MainActor () async -> Void
    ) {
        muteTask?.cancel()
        muteTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    func schedulePause(operation: @escaping @MainActor () async -> Void) {
        pauseTask?.cancel()
        pauseTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    func cancelStartTasks() {
        muteTask?.cancel()
        muteTask = nil
        pauseTask?.cancel()
        pauseTask = nil
    }

    func cancelRestoration() {
        restorationTask?.cancel()
        restorationTask = nil
    }

    func restoreAudio(
        unmute: @escaping @MainActor () async -> Void,
        resume: @escaping @MainActor () async -> Void
    ) {
        cancelStartTasks()
        cancelRestoration()
        restorationTask = Task { @MainActor in
            await unmute()
            guard !Task.isCancelled else { return }
            await resume()
        }
    }

    nonisolated func cancelAll() {
        muteTask?.cancel()
        muteTask = nil
        pauseTask?.cancel()
        pauseTask = nil
        restorationTask?.cancel()
        restorationTask = nil
    }
}
