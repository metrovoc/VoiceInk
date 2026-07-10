import Foundation
import AppKit

struct RecordingContextSnapshot: Sendable {
    var capturedAt = Date()
    var selectedText: String?
    var clipboardText: String?
    var screenText: String?
}

/// The application/window identity is frozen at the recording trigger. Heavy
/// AX and ScreenCaptureKit work may happen later, but it must never silently
/// switch to whichever application happens to be frontmost at that time.
struct RecordingContextTarget: Equatable, Sendable {
    let processID: pid_t
    let bundleIdentifier: String?
    let applicationName: String?
}

struct RecordingContextWindowHint: Equatable, Sendable {
    let processID: pid_t
    let title: String?
    let frame: CGRect?
}

struct RecordingContextTriggerSnapshot: Equatable, Sendable {
    let capturedAt: Date
    let clipboardText: String?
    let capturingProcessID: pid_t
    let target: RecordingContextTarget?
    let windowHint: RecordingContextWindowHint?

    init(
        capturedAt: Date = Date(),
        clipboardText: String?,
        capturingProcessID: pid_t = ProcessInfo.processInfo.processIdentifier,
        target: RecordingContextTarget?,
        windowHint: RecordingContextWindowHint?
    ) {
        self.capturedAt = capturedAt
        self.clipboardText = clipboardText
        self.capturingProcessID = capturingProcessID
        self.target = target
        self.windowHint = windowHint
    }

    /// Keep this synchronous and tiny. Clipboard is deliberately read first:
    /// the selected-text menu fallback temporarily changes the pasteboard.
    @MainActor
    static func capture() -> RecordingContextTriggerSnapshot {
        let clipboardText = NSPasteboard.general.string(forType: .string)
        let capturingProcessID = ProcessInfo.processInfo.processIdentifier
        let frontmostApplication = NSWorkspace.shared.frontmostApplication

        guard let frontmostApplication,
              frontmostApplication.processIdentifier != capturingProcessID else {
            return RecordingContextTriggerSnapshot(
                clipboardText: clipboardText,
                capturingProcessID: capturingProcessID,
                target: nil,
                windowHint: nil
            )
        }

        let target = RecordingContextTarget(
            processID: frontmostApplication.processIdentifier,
            bundleIdentifier: frontmostApplication.bundleIdentifier,
            applicationName: frontmostApplication.localizedName
        )
        return RecordingContextTriggerSnapshot(
            clipboardText: clipboardText,
            capturingProcessID: capturingProcessID,
            target: target,
            windowHint: RecordingContextWindowHint(
                processID: target.processID,
                title: nil,
                frame: nil
            )
        )
    }
}

/// An immutable description of the context work a recording actually needs.
/// Keeping this separate from the capture implementation makes an empty plan a
/// true no-op: no tasks, pasteboard reads, AX calls, or capture objects exist.
struct RecordingContextCapturePlan: Equatable, Sendable {
    let capturesClipboard: Bool
    let capturesSelectedText: Bool
    let capturesScreen: Bool

    static let none = RecordingContextCapturePlan(
        capturesClipboard: false,
        capturesSelectedText: false,
        capturesScreen: false
    )

    var isEmpty: Bool {
        !capturesClipboard && !capturesSelectedText && !capturesScreen
    }

    init(
        capturesClipboard: Bool,
        capturesSelectedText: Bool,
        capturesScreen: Bool
    ) {
        self.capturesClipboard = capturesClipboard
        self.capturesSelectedText = capturesSelectedText
        self.capturesScreen = capturesScreen
    }

    init(configuration: EnhancementRuntimeConfiguration?) {
        guard let configuration, configuration.isEnabled else {
            self = .none
            return
        }

        self.init(
            capturesClipboard: configuration.useClipboardContext,
            capturesSelectedText: configuration.useSelectedTextContext,
            capturesScreen: configuration.useScreenCaptureContext
        )
    }

    init(mode: ModeConfig?) {
        guard let mode, mode.isEnabled, mode.isAIEnhancementEnabled else {
            self = .none
            return
        }

        self.init(
            capturesClipboard: mode.useClipboardContext,
            capturesSelectedText: mode.useSelectedTextContext,
            capturesScreen: mode.useScreenCapture
        )
    }
}

private enum RecordingContextCapability: Hashable, Sendable {
    case clipboard
    case selectedText
    case screen
}

private final class RecordingContextReadinessRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RecordingContextSnapshot, Never>?
    private var resolvedSnapshot: RecordingContextSnapshot?
    private var isResolved = false

    func wait() async -> RecordingContextSnapshot {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isResolved, let resolvedSnapshot {
                lock.unlock()
                continuation.resume(returning: resolvedSnapshot)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resolve(with snapshot: RecordingContextSnapshot) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        resolvedSnapshot = snapshot
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: snapshot)
    }
}

/// Lock-backed because capture completions arrive from independent executors.
/// This store is touched only a handful of times per recording; it never
/// publishes changes or schedules MainActor work.
final class RecordingContextSnapshotStore: @unchecked Sendable {
    private struct Waiter {
        let requiredCapabilities: Set<RecordingContextCapability>
        let race: RecordingContextReadinessRace
    }

    private let lock = NSLock()
    private var storedSnapshot: RecordingContextSnapshot
    private var activeCapabilities = Set<RecordingContextCapability>()
    private var completedCapabilities = Set<RecordingContextCapability>()
    private var waiters: [UUID: Waiter] = [:]

    init(capturedAt: Date = Date()) {
        storedSnapshot = RecordingContextSnapshot(capturedAt: capturedAt)
    }

    var snapshot: RecordingContextSnapshot {
        lock.lock()
        let snapshot = storedSnapshot
        lock.unlock()
        return snapshot
    }

    fileprivate func reconcile(to capabilities: Set<RecordingContextCapability>) {
        lock.lock()
        activeCapabilities = capabilities
        completedCapabilities.formIntersection(capabilities)
        if !capabilities.contains(.clipboard) {
            storedSnapshot.clipboardText = nil
        }
        if !capabilities.contains(.selectedText) {
            storedSnapshot.selectedText = nil
        }
        if !capabilities.contains(.screen) {
            storedSnapshot.screenText = nil
        }
        let resolutions = readyWaiterResolutionsLocked()
        lock.unlock()
        resolve(resolutions)
    }

    fileprivate func begin(_ capability: RecordingContextCapability) {
        lock.lock()
        activeCapabilities.insert(capability)
        completedCapabilities.remove(capability)
        lock.unlock()
    }

    fileprivate func complete(_ capability: RecordingContextCapability, text: String?) {
        lock.lock()
        guard activeCapabilities.contains(capability) else {
            lock.unlock()
            return
        }

        let normalizedText = Self.normalized(text)
        switch capability {
        case .clipboard:
            storedSnapshot.clipboardText = normalizedText
        case .selectedText:
            storedSnapshot.selectedText = normalizedText
        case .screen:
            storedSnapshot.screenText = normalizedText
        }
        completedCapabilities.insert(capability)
        let resolutions = readyWaiterResolutionsLocked()
        lock.unlock()
        resolve(resolutions)
    }

    fileprivate func snapshotAwaiting(
        _ requiredCapabilities: Set<RecordingContextCapability>,
        timeoutNanoseconds: UInt64
    ) async -> RecordingContextSnapshot {
        let waiterID = UUID()
        let race = RecordingContextReadinessRace()

        let immediatelyAvailableSnapshot: RecordingContextSnapshot? = withLock {
            guard !isReadyLocked(requiredCapabilities), timeoutNanoseconds > 0 else {
                return storedSnapshot
            }
            waiters[waiterID] = Waiter(
                requiredCapabilities: requiredCapabilities,
                race: race
            )
            return nil
        }
        if let immediatelyAvailableSnapshot {
            return immediatelyAvailableSnapshot
        }

        Task.detached(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            self?.resolveWaiter(waiterID)
        }

        return await withTaskCancellationHandler {
            await race.wait()
        } onCancel: { [weak self] in
            self?.resolveWaiter(waiterID)
        }
    }

    /// Async callers enter the lock only through this synchronous scope. The
    /// critical section cannot suspend and remains valid under Swift 6's ban
    /// on direct `lock()`/`unlock()` calls from async functions.
    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func resolveWaiter(_ waiterID: UUID) {
        lock.lock()
        guard let waiter = waiters.removeValue(forKey: waiterID) else {
            lock.unlock()
            return
        }
        let snapshot = storedSnapshot
        lock.unlock()
        waiter.race.resolve(with: snapshot)
    }

    private func isReadyLocked(_ requiredCapabilities: Set<RecordingContextCapability>) -> Bool {
        requiredCapabilities
            .intersection(activeCapabilities)
            .isSubset(of: completedCapabilities)
    }

    private func readyWaiterResolutionsLocked() -> [(RecordingContextReadinessRace, RecordingContextSnapshot)] {
        let readyIDs = waiters.compactMap { id, waiter in
            isReadyLocked(waiter.requiredCapabilities) ? id : nil
        }
        guard !readyIDs.isEmpty else { return [] }

        let snapshot = storedSnapshot
        return readyIDs.compactMap { id in
            waiters.removeValue(forKey: id).map { ($0.race, snapshot) }
        }
    }

    private func resolve(_ resolutions: [(RecordingContextReadinessRace, RecordingContextSnapshot)]) {
        for (race, snapshot) in resolutions {
            race.resolve(with: snapshot)
        }
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
final class RecordingContextCapture {
    typealias CaptureOperation = @Sendable (RecordingContextTriggerSnapshot) async -> String?

    /// This wait happens only immediately before enhancement consumes context.
    /// Recorder startup, audio capture, and realtime preconnect never call it.
    nonisolated static let enhancementReadinessBudgetNanoseconds: UInt64 = 250_000_000

    let store: RecordingContextSnapshotStore
    let triggerSnapshot: RecordingContextTriggerSnapshot

    private(set) var plan: RecordingContextCapturePlan = .none
    private var startedCapabilities = Set<RecordingContextCapability>()
    private var tasks: [RecordingContextCapability: Task<Void, Never>] = [:]
    private let selectedText: CaptureOperation
    private let screenText: CaptureOperation

    /// Number of independently executing side-lane operations. Clipboard is
    /// frozen synchronously and therefore is intentionally not a task.
    var taskCount: Int {
        tasks.count
    }

    init(
        plan: RecordingContextCapturePlan,
        store: RecordingContextSnapshotStore? = nil,
        triggerSnapshot: RecordingContextTriggerSnapshot? = nil,
        selectedText: @escaping CaptureOperation = { triggerSnapshot in
            await SelectedTextService.fetchSelectedText(target: triggerSnapshot.target)
        },
        screenText: @escaping CaptureOperation = { triggerSnapshot in
            guard CGPreflightScreenCaptureAccess(),
                  let windowHint = triggerSnapshot.windowHint else {
                return nil
            }
            return await ScreenCaptureService.captureAndExtractText(
                focusedWindowHint: windowHint,
                currentPID: triggerSnapshot.capturingProcessID
            )
        }
    ) {
        let triggerSnapshot = triggerSnapshot ?? RecordingContextTriggerSnapshot.capture()
        self.triggerSnapshot = triggerSnapshot
        self.store = store ?? RecordingContextSnapshotStore(capturedAt: triggerSnapshot.capturedAt)
        self.selectedText = selectedText
        self.screenText = screenText
        reconcile(to: plan)
    }

    var snapshot: RecordingContextSnapshot {
        store.snapshot
    }

    func snapshotAwaitingReadiness(
        timeoutNanoseconds: UInt64 = RecordingContextCapture.enhancementReadinessBudgetNanoseconds
    ) async -> RecordingContextSnapshot {
        await store.snapshotAwaiting(
            capabilities(for: plan),
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    func reconcile(to newPlan: RecordingContextCapturePlan) {
        let desiredCapabilities = capabilities(for: newPlan)
        let existingCapabilities = startedCapabilities

        for capability in existingCapabilities.subtracting(desiredCapabilities) {
            tasks.removeValue(forKey: capability)?.cancel()
            startedCapabilities.remove(capability)
        }

        store.reconcile(to: desiredCapabilities)
        plan = newPlan

        let addedCapabilities = desiredCapabilities.subtracting(existingCapabilities)
        // Clipboard completion is synchronous and always precedes submission
        // of any task that might temporarily mutate the pasteboard.
        if addedCapabilities.contains(.clipboard) {
            startCapture(for: .clipboard)
        }
        if addedCapabilities.contains(.selectedText) {
            startCapture(for: .selectedText)
        }
        if addedCapabilities.contains(.screen) {
            startCapture(for: .screen)
        }
    }

    func cancel() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        startedCapabilities.removeAll()
        plan = .none
        store.reconcile(to: [])
    }

    deinit {
        tasks.values.forEach { $0.cancel() }
    }

    private func capabilities(for plan: RecordingContextCapturePlan) -> Set<RecordingContextCapability> {
        var capabilities = Set<RecordingContextCapability>()
        if plan.capturesClipboard { capabilities.insert(.clipboard) }
        if plan.capturesSelectedText { capabilities.insert(.selectedText) }
        if plan.capturesScreen { capabilities.insert(.screen) }
        return capabilities
    }

    private func startCapture(for capability: RecordingContextCapability) {
        startedCapabilities.insert(capability)
        store.begin(capability)

        switch capability {
        case .clipboard:
            // The value was frozen before any selected-text task was submitted.
            store.complete(.clipboard, text: triggerSnapshot.clipboardText)

        case .selectedText:
            tasks[capability] = Task.detached(priority: .utility) {
                [weak store, selectedText, triggerSnapshot] in
                guard !Task.isCancelled else { return }
                let text = await selectedText(triggerSnapshot)
                guard !Task.isCancelled else { return }
                store?.complete(.selectedText, text: text)
            }

        case .screen:
            tasks[capability] = Task.detached(priority: .utility) {
                [weak store, screenText, triggerSnapshot] in
                guard !Task.isCancelled else { return }
                let text = await screenText(triggerSnapshot)
                guard !Task.isCancelled else { return }
                store?.complete(.screen, text: text)
            }
        }
    }
}

@MainActor
enum RecordingContextCaptureService {
    static func startCapture(plan: RecordingContextCapturePlan) -> RecordingContextCapture? {
        guard !plan.isEmpty else { return nil }
        return RecordingContextCapture(plan: plan)
    }
}
