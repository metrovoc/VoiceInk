import Foundation
import os

/// Local latency budgets for the realtime path. These intentionally exclude
/// hardware bring-up, network RTT, and provider inference time: those are
/// observable external latency, not work the app is allowed to add itself.
enum RealtimePerformanceBudget {
    static let mainActorDispatch: TimeInterval = 1.0 / 60.0
    static let recordingRequestToPreconnect: TimeInterval = 0.050
    static let stopRequestToCommit: TimeInterval = 0.050
    static let partialReceiveToPublish: TimeInterval = 0.050
    static let maximumStreamingQueueAge: TimeInterval = 0.100
}

enum RealtimePerformanceMilestone: String, CaseIterable, Sendable {
    case recordingRequested
    case audioCaptureStarted
    case preconnectRequested
    case streamingConnected
    case firstPartialReceived
    case firstPartialPublished
    case stopRequested
    case commitRequested
    case finalReceived
    case delivered
}

struct RealtimePerformanceSnapshot: Sendable, Equatable {
    let sessionID: UUID
    let timestamps: [RealtimePerformanceMilestone: TimeInterval]

    func interval(
        from start: RealtimePerformanceMilestone,
        to end: RealtimePerformanceMilestone
    ) -> TimeInterval? {
        guard let startTime = timestamps[start], let endTime = timestamps[end] else {
            return nil
        }
        return max(0, endTime - startTime)
    }

    var requestToPreconnect: TimeInterval? {
        interval(from: .recordingRequested, to: .preconnectRequested)
    }

    var requestToAudioCapture: TimeInterval? {
        interval(from: .recordingRequested, to: .audioCaptureStarted)
    }

    var stopToCommit: TimeInterval? {
        interval(from: .stopRequested, to: .commitRequested)
    }

    var partialToPublish: TimeInterval? {
        interval(from: .firstPartialReceived, to: .firstPartialPublished)
    }
}

/// Per-recording monotonic trace. It is deliberately independent of actors so
/// the control plane and streaming core can mark the same session without an
/// executor hop. Marks are first-writer-wins to keep retries idempotent.
final class RealtimePerformanceTrace: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: AppIdentity.loggerSubsystem,
        category: "RealtimePerformance"
    )

    let sessionID: UUID

    private let lock = NSLock()
    private var timestamps: [RealtimePerformanceMilestone: TimeInterval] = [:]

    init(sessionID: UUID = UUID()) {
        self.sessionID = sessionID
    }

    func mark(
        _ milestone: RealtimePerformanceMilestone,
        at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        lock.lock()
        if timestamps[milestone] == nil {
            timestamps[milestone] = timestamp
        }
        lock.unlock()
    }

    func snapshot() -> RealtimePerformanceSnapshot {
        lock.lock()
        let snapshot = RealtimePerformanceSnapshot(
            sessionID: sessionID,
            timestamps: timestamps
        )
        lock.unlock()
        return snapshot
    }

    func logSummary() {
        let snapshot = snapshot()
        let requestToPreconnect = snapshot.requestToPreconnect ?? -1
        let requestToAudioCapture = snapshot.requestToAudioCapture ?? -1
        let stopToCommit = snapshot.stopToCommit ?? -1
        let partialToPublish = snapshot.partialToPublish ?? -1

        Self.logger.notice(
            "Realtime trace session=\(self.sessionID.uuidString, privacy: .public) requestToPreconnect=\(requestToPreconnect, format: .fixed(precision: 3), privacy: .public)s requestToAudioCapture=\(requestToAudioCapture, format: .fixed(precision: 3), privacy: .public)s stopToCommit=\(stopToCommit, format: .fixed(precision: 3), privacy: .public)s partialToPublish=\(partialToPublish, format: .fixed(precision: 3), privacy: .public)s"
        )

        warnIfOverBudget(
            name: "requestToPreconnect",
            value: snapshot.requestToPreconnect,
            budget: RealtimePerformanceBudget.recordingRequestToPreconnect
        )
        warnIfOverBudget(
            name: "stopToCommit",
            value: snapshot.stopToCommit,
            budget: RealtimePerformanceBudget.stopRequestToCommit
        )
        warnIfOverBudget(
            name: "partialToPublish",
            value: snapshot.partialToPublish,
            budget: RealtimePerformanceBudget.partialReceiveToPublish
        )
    }

    private func warnIfOverBudget(name: String, value: TimeInterval?, budget: TimeInterval) {
        guard let value, value > budget else { return }
        Self.logger.warning(
            "Realtime local latency exceeded session=\(self.sessionID.uuidString, privacy: .public) metric=\(name, privacy: .public) elapsed=\(value, format: .fixed(precision: 3), privacy: .public)s budget=\(budget, format: .fixed(precision: 3), privacy: .public)s"
        )
    }
}
