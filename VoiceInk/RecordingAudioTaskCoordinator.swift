import Foundation

final class RecordingAudioTaskCoordinator {
    private var muteTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var restorationTask: Task<Void, Never>?

    func scheduleMute(afterDelayNanoseconds delay: UInt64, operation: @escaping () async -> Void) {
        muteTask?.cancel()
        muteTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    func schedulePause(operation: @escaping () async -> Void) {
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

    func restoreAudio(unmute: @escaping () async -> Void, resume: @escaping () async -> Void) {
        cancelStartTasks()
        cancelRestoration()
        restorationTask = Task { @MainActor in
            await unmute()
            guard !Task.isCancelled else { return }
            await resume()
        }
    }

    func cancelAll() {
        cancelStartTasks()
        cancelRestoration()
    }
}
