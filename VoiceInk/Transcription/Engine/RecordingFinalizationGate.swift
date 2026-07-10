import Foundation

/// Serializes all UI, shortcut, and deferred-start stop requests onto one
/// recording finalization operation. Re-entrant callers join the active task
/// instead of issuing another hardware stop, provider commit, or persistence
/// pipeline.
@MainActor
final class RecordingFinalizationGate {
    private struct Entry {
        let operationID: UUID
        let task: Task<Void, Never>
    }

    private var tasks: [UUID: Entry] = [:]

    var isFinalizing: Bool {
        !tasks.isEmpty
    }

    /// Deduplicates finalization for one recording generation without allowing
    /// an older transcription/enhancement pipeline to block a newer recording.
    func run(
        recordingID: UUID,
        _ operation: @escaping @MainActor () async -> Void
    ) async {
        if let entry = tasks[recordingID] {
            await entry.task.value
            return
        }

        let operationID = UUID()
        let task = Task { @MainActor in
            await operation()
        }
        tasks[recordingID] = Entry(operationID: operationID, task: task)

        await task.value
        guard tasks[recordingID]?.operationID == operationID else { return }
        tasks[recordingID] = nil
    }
}
