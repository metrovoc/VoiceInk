import Foundation
import SwiftData
import Testing
@testable import VoiceInk_CE

struct RecordingPersistenceCoordinatorTests {
    @MainActor
    @Test func pendingRecordingIsDurableAndIdempotentBeforePipelineCompletion() async throws {
        let schema = Schema([Transcription.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        // VoiceInk's presentation context already exists before the detached
        // pending upsert; resolution must work in that long-lived context.
        let presentationContext = ModelContext(container)
        let draft = PendingRecordingDraft(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_234),
            audioFileURL: "file:///tmp/voiceink-durable.wav",
            transcriptionModelName: "Realtime",
            modeName: "Dictation",
            modeEmoji: "🎙️"
        )

        let first = await RecordingPersistenceCoordinator
            .beginPersistingPending(draft, in: container).value
        let second = await RecordingPersistenceCoordinator
            .beginPersistingPending(draft, in: container).value

        #expect(first)
        #expect(second)
        let rows = try presentationContext.fetch(FetchDescriptor<Transcription>())
        #expect(rows.count == 1)
        #expect(rows.first?.id == draft.id)
        #expect(rows.first?.transcriptionStatus == TranscriptionStatus.pending.rawValue)
        #expect(rows.first?.audioFileURL == draft.audioFileURL)
        #expect(
            RecordingPersistenceCoordinator.resolve(
                id: draft.id,
                in: presentationContext
            )?.id == draft.id
        )
    }
}
