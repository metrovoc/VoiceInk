import Foundation
import SwiftData
import Testing
@testable import VoiceInk_CE

private actor VocabularyLoaderProbe {
    private var nextTerms: [String]
    private var loads = 0
    private let delayNanoseconds: UInt64

    init(terms: [String], delayNanoseconds: UInt64 = 0) {
        nextTerms = terms
        self.delayNanoseconds = delayNanoseconds
    }

    func load() async -> StreamingVocabularySnapshot {
        loads += 1
        let terms = nextTerms
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return StreamingVocabularySnapshot(terms: terms)
    }

    func update(terms: [String]) {
        nextTerms = terms
    }

    var loadCount: Int { loads }
}

private final class MainActorBlockingGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func blockMainActor() {
        entered.signal()
        _ = release.wait(timeout: .now() + 2)
    }

    func waitUntilEntered() -> Bool {
        entered.wait(timeout: .now() + 1) == .success
    }

    func unblock() {
        release.signal()
    }
}

private final class VocabularyFactoryObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTerms: [String]?

    var terms: [String]? {
        lock.lock()
        let terms = storedTerms
        lock.unlock()
        return terms
    }

    func record(_ terms: [String]) {
        lock.lock()
        storedTerms = terms
        lock.unlock()
    }
}

private final class VocabularyTestStreamingProvider:
    StreamingTranscriptionProvider,
    @unchecked Sendable
{
    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>
    private let continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation

    init() {
        let pair = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
        transcriptionEvents = pair.stream
        continuation = pair.continuation
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        continuation.yield(.sessionStarted)
    }

    func sendAudioChunk(_ data: Data) async throws {}

    func commit() async throws {
        continuation.yield(.finalized)
    }

    func disconnect() async {
        continuation.finish()
    }
}

@Suite(.serialized)
struct StreamingVocabularySnapshotStoreTests {
    @Test func cacheMissAndHitCompleteWhileMainActorIsBlocked() async throws {
        let container = try makeVocabularyContainer()
        let probe = VocabularyLoaderProbe(terms: ["VoiceInk"])
        let store = StreamingVocabularySnapshotStore(
            observesModelSaves: false,
            loader: { _ in await probe.load() }
        )
        let gate = MainActorBlockingGate()
        let blocker = Task { @MainActor in
            gate.blockMainActor()
        }
        #expect(gate.waitUntilEntered())

        let loaded = await Task.detached {
            await store.snapshot(for: container)
        }.value
        let cached = await Task.detached {
            await store.snapshot(for: container)
        }.value

        gate.unblock()
        await blocker.value

        #expect(loaded.terms == ["VoiceInk"])
        #expect(cached == loaded)
        #expect(await probe.loadCount == 1)
    }

    @Test func concurrentMissesCoalesceIntoOneLoad() async throws {
        let container = try makeVocabularyContainer()
        let probe = VocabularyLoaderProbe(
            terms: ["coalesced"],
            delayNanoseconds: 50_000_000
        )
        let store = StreamingVocabularySnapshotStore(
            observesModelSaves: false,
            loader: { _ in await probe.load() }
        )

        let snapshots = await withTaskGroup(of: StreamingVocabularySnapshot.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    await store.snapshot(for: container)
                }
            }
            var snapshots: [StreamingVocabularySnapshot] = []
            for await snapshot in group {
                snapshots.append(snapshot)
            }
            return snapshots
        }

        #expect(snapshots.count == 64)
        #expect(snapshots.allSatisfy { $0.terms == ["coalesced"] })
        #expect(await probe.loadCount == 1)
    }

    @MainActor
    @Test func onlyVocabularySavesInvalidateTheContainerSnapshot() async throws {
        let container = try makeVocabularyContainer()
        let probe = VocabularyLoaderProbe(terms: ["initial"])
        let store = StreamingVocabularySnapshotStore(
            loader: { _ in await probe.load() }
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let initial = await store.snapshot(for: container)
        #expect(initial.terms == ["initial"])
        #expect(await probe.loadCount == 1)

        await probe.update(terms: ["must stay cached"])
        context.insert(WordReplacement(originalText: "before", replacementText: "after"))
        try context.save()

        let afterUnrelatedSave = await store.snapshot(for: container)
        #expect(afterUnrelatedSave.terms == ["initial"])
        #expect(await probe.loadCount == 1)

        await probe.update(terms: ["refreshed"])
        context.insert(VocabularyWord(word: "new vocabulary"))
        try context.save()

        let afterVocabularySave = await store.snapshot(for: container)
        #expect(afterVocabularySave.terms == ["refreshed"])
        #expect(await probe.loadCount == 2)
    }

    @MainActor
    @Test func requestStartReturnsBeforeVocabularyLoadAndFactoryConstruction() async throws {
        let container = try makeVocabularyContainer()
        let probe = VocabularyLoaderProbe(
            terms: ["domain term"],
            delayNanoseconds: 100_000_000
        )
        let store = StreamingVocabularySnapshotStore(
            observesModelSaves: false,
            loader: { _ in await probe.load() }
        )
        let observation = VocabularyFactoryObservation()
        let provider = VocabularyTestStreamingProvider()
        let service = StreamingTranscriptionService(
            modelContainer: container,
            providerFactory: { _, vocabulary, _ in
                observation.record(vocabulary)
                return provider
            },
            vocabularySnapshotStore: store
        )
        let model = CloudModel(
            name: "vocabulary-start-test",
            displayName: "Vocabulary Start Test",
            description: "Test",
            provider: .deepgram,
            speed: 1,
            accuracy: 1,
            isMultilingual: true,
            supportsStreaming: true,
            supportedLanguages: ["en": "English"]
        )

        let startedAt = ProcessInfo.processInfo.systemUptime
        let startTask = service.requestStartTask(
            model: model,
            context: TranscriptionRequestContext(language: "en", prompt: nil)
        )
        let submissionElapsed = ProcessInfo.processInfo.systemUptime - startedAt

        #expect(submissionElapsed < 0.050)
        #expect(observation.terms == nil)

        try await startTask.value
        #expect(observation.terms == ["domain term"])
        service.cancel()
    }
}

private func makeVocabularyContainer() throws -> ModelContainer {
    let schema = Schema([
        VocabularyWord.self,
        WordReplacement.self
    ])
    let configuration = ModelConfiguration(
        schema: schema,
        isStoredInMemoryOnly: true
    )
    return try ModelContainer(for: schema, configurations: [configuration])
}
