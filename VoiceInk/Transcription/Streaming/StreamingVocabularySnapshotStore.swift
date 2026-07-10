import Foundation
import SwiftData

struct StreamingVocabularySnapshot: Equatable, Sendable {
    static let empty = StreamingVocabularySnapshot(terms: [])

    let terms: [String]

    init(terms: [String]) {
        var seen = Set<String>()
        var normalizedTerms: [String] = []
        normalizedTerms.reserveCapacity(terms.count)

        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            normalizedTerms.append(trimmed)
        }
        self.terms = normalizedTerms
    }

    func terms(limit: Int?) -> [String] {
        guard let limit else { return terms }
        return Array(terms.prefix(max(0, limit)))
    }
}

/// Immutable ownership token for a container handed to a newly-created
/// background ModelContext. It also supplies a stable per-container cache key
/// and makes the deliberate detached-task boundary explicit.
struct StreamingVocabularyContainerReference: @unchecked Sendable {
    let container: ModelContainer
    let identifier: ObjectIdentifier

    init(_ container: ModelContainer) {
        self.container = container
        self.identifier = ObjectIdentifier(container)
    }
}

/// Process-wide, per-container vocabulary snapshots. The lock protects only
/// tiny cache metadata. SwiftData fetches execute in detached load tasks and
/// concurrent misses for the same generation share one task.
final class StreamingVocabularySnapshotStore: @unchecked Sendable {
    typealias Loader = @Sendable (
        StreamingVocabularyContainerReference
    ) async -> StreamingVocabularySnapshot

    static let shared = StreamingVocabularySnapshotStore()

    private struct InFlightLoad {
        let token: UUID
        let generation: UInt64
        let task: Task<StreamingVocabularySnapshot, Never>
    }

    private struct Entry {
        var generation: UInt64 = 0
        var snapshot: StreamingVocabularySnapshot?
        var inFlight: InFlightLoad?
    }

    private enum Lookup {
        case cached(StreamingVocabularySnapshot)
        case loading(InFlightLoad)
    }

    private let lock = NSLock()
    private let loader: Loader
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var saveObserver: NSObjectProtocol?

    init(
        observesModelSaves: Bool = true,
        loader: Loader? = nil
    ) {
        if let loader {
            self.loader = loader
        } else {
            self.loader = { reference in
                await Self.loadFromSwiftData(reference: reference)
            }
        }

        if observesModelSaves {
            saveObserver = NotificationCenter.default.addObserver(
                forName: ModelContext.didSave,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                self?.handleModelContextSave(notification)
            }
        }
    }

    deinit {
        if let saveObserver {
            NotificationCenter.default.removeObserver(saveObserver)
        }
    }

    func snapshot(for container: ModelContainer) async -> StreamingVocabularySnapshot {
        await snapshot(for: StreamingVocabularyContainerReference(container))
    }

    func snapshot(
        for reference: StreamingVocabularyContainerReference
    ) async -> StreamingVocabularySnapshot {

        while !Task.isCancelled {
            let lookup = lookup(for: reference)
            switch lookup {
            case .cached(let snapshot):
                return snapshot

            case .loading(let load):
                let loadedSnapshot = await load.task.value
                if let currentSnapshot = finish(
                    load,
                    loadedSnapshot: loadedSnapshot,
                    containerID: reference.identifier
                ) {
                    return currentSnapshot
                }
                // A vocabulary save invalidated this generation while its load
                // was in flight. Loop and join/start the current generation.
            }
        }

        return .empty
    }

    /// Synchronous invalidation is intentional: once a vocabulary save
    /// returns, a subsequent preconnect cannot race ahead and see stale terms.
    func invalidate(for container: ModelContainer) {
        let identifier = ObjectIdentifier(container)
        withLock {
            var entry = entries[identifier] ?? Entry()
            entry.generation &+= 1
            entry.snapshot = nil
            // Do not cancel an old fetch: existing callers will observe the
            // generation mismatch and coalesce on the new load.
            entry.inFlight = nil
            entries[identifier] = entry
        }
    }

    private func lookup(for reference: StreamingVocabularyContainerReference) -> Lookup {
        withLock {
            var entry = entries[reference.identifier] ?? Entry()
            if let snapshot = entry.snapshot {
                return .cached(snapshot)
            }
            if let inFlight = entry.inFlight,
               inFlight.generation == entry.generation {
                return .loading(inFlight)
            }

            let token = UUID()
            let generation = entry.generation
            let loader = loader
            let task = Task.detached(priority: .userInitiated) {
                await loader(reference)
            }
            let load = InFlightLoad(
                token: token,
                generation: generation,
                task: task
            )
            entry.inFlight = load
            entries[reference.identifier] = entry
            return .loading(load)
        }
    }

    private func finish(
        _ load: InFlightLoad,
        loadedSnapshot: StreamingVocabularySnapshot,
        containerID: ObjectIdentifier
    ) -> StreamingVocabularySnapshot? {
        withLock {
            guard var entry = entries[containerID] else { return nil }

            if entry.generation != load.generation {
                return nil
            }
            if let snapshot = entry.snapshot {
                return snapshot
            }
            guard entry.inFlight?.token == load.token else {
                return nil
            }

            entry.snapshot = loadedSnapshot
            entry.inFlight = nil
            entries[containerID] = entry
            return loadedSnapshot
        }
    }

    private func handleModelContextSave(_ notification: Notification) {
        guard let context = notification.object as? ModelContext,
              Self.containsVocabularyChange(notification.userInfo) else {
            return
        }
        invalidate(for: context.container)
    }

    private static func containsVocabularyChange(_ userInfo: [AnyHashable: Any]?) -> Bool {
        guard let userInfo else { return false }
        let keys: [ModelContext.NotificationKey] = [
            .insertedIdentifiers,
            .updatedIdentifiers,
            .deletedIdentifiers
        ]

        return keys.contains { key in
            identifiers(for: key, in: userInfo).contains { identifier in
                identifier.entityName == "VocabularyWord" ||
                    identifier.entityName.hasSuffix(".VocabularyWord")
            }
        }
    }

    private static func identifiers(
        for key: ModelContext.NotificationKey,
        in userInfo: [AnyHashable: Any]
    ) -> [PersistentIdentifier] {
        let value = userInfo[key] ?? userInfo[key.rawValue]
        if let identifiers = value as? Set<PersistentIdentifier> {
            return Array(identifiers)
        }
        if let identifiers = value as? [PersistentIdentifier] {
            return identifiers
        }
        return []
    }

    private nonisolated static func loadFromSwiftData(
        reference: StreamingVocabularyContainerReference
    ) async -> StreamingVocabularySnapshot {
        let entityNames = reference.container.schema.entitiesByName.keys
        guard entityNames.contains(where: {
            $0 == "VocabularyWord" || $0.hasSuffix(".VocabularyWord")
        }) else {
            return .empty
        }

        let context = ModelContext(reference.container)
        context.autosaveEnabled = false
        // Sort immutable strings after the fetch. SwiftData's generated
        // SortDescriptor key-path currently carries a false non-Sendable
        // diagnostic under complete strict-concurrency checking.
        let descriptor = FetchDescriptor<VocabularyWord>()
        let terms = ((try? context.fetch(descriptor).map(\.word)) ?? [])
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return StreamingVocabularySnapshot(terms: terms)
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
