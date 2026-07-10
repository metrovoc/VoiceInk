import Foundation
import SwiftData
import os

/// Sendable representation of the durable record created immediately after
/// provider finalization is handed off. The WAV is therefore never orphaned by
/// a slow API/enhancement/delivery phase or an app termination during it.
struct PendingRecordingDraft: Sendable, Equatable {
    let id: UUID
    let timestamp: Date
    let audioFileURL: String
    let transcriptionModelName: String?
    let modeName: String?
    let modeEmoji: String?

    func makeTranscription() -> Transcription {
        let transcription = Transcription(
            text: "",
            duration: 0,
            audioFileURL: audioFileURL,
            transcriptionModelName: transcriptionModelName,
            modeName: modeName,
            modeEmoji: modeEmoji,
            transcriptionStatus: .pending
        )
        transcription.id = id
        transcription.timestamp = timestamp
        return transcription
    }
}

enum RecordingPersistenceCoordinator {
    private static let logger = Logger(
        subsystem: AppIdentity.loggerSubsystem,
        category: "RecordingPersistence"
    )

    /// Starts a background-context upsert synchronously. Callers can overlap
    /// this disk work with hardware/file draining; no MainActor work is needed
    /// until the saved object is resolved for the presentation pipeline.
    static func beginPersistingPending(
        _ draft: PendingRecordingDraft,
        in container: ModelContainer
    ) -> Task<Bool, Never> {
        Task.detached(priority: .utility) {
            let context = ModelContext(container)
            let recordingID = draft.id
            let descriptor = FetchDescriptor<Transcription>(
                predicate: #Predicate { $0.id == recordingID }
            )

            do {
                if try context.fetchCount(descriptor) == 0 {
                    context.insert(draft.makeTranscription())
                    try context.save()
                }
                return true
            } catch {
                logger.error(
                    "Failed to persist pending recording id=\(recordingID.uuidString, privacy: .public) error=\(error, privacy: .public)"
                )
                return false
            }
        }
    }

    @MainActor
    static func resolve(
        id: UUID,
        in context: ModelContext
    ) -> Transcription? {
        var descriptor = FetchDescriptor<Transcription>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
