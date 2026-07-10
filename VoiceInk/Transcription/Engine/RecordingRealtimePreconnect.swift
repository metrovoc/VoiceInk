import Foundation

struct PreparedRealtimeSession: @unchecked Sendable {
    let configuration: TranscriptionRuntimeConfiguration
    let session: TranscriptionSession
    let audioChunkCallback: RecordingAudioChunkHandler
}

struct EarlyRealtimePreconnect {
    let configuration: TranscriptionRuntimeConfiguration
    let task: Task<PreparedRealtimeSession?, Error>
}

enum RecordingRealtimePreconnectLifecycle {
    @MainActor
    static func begin(
        configuration: TranscriptionRuntimeConfiguration,
        startupStartedAt: TimeInterval,
        prepare: @escaping @MainActor () async throws -> PreparedRealtimeSession?,
        onPrepared: @escaping @MainActor (
            _ configuration: TranscriptionRuntimeConfiguration,
            _ startupElapsed: TimeInterval,
            _ prepareDuration: TimeInterval
        ) -> Void = { _, _, _ in }
    ) -> EarlyRealtimePreconnect {
        let task = Task(priority: .userInitiated) { @MainActor in
            let preconnectStartedAt = ProcessInfo.processInfo.systemUptime
            try Task.checkCancellation()
            let preparedSession = try await prepare()

            if Task.isCancelled {
                preparedSession?.session.cancel()
                throw CancellationError()
            }

            if preparedSession != nil {
                let now = ProcessInfo.processInfo.systemUptime
                onPrepared(
                    configuration,
                    now - startupStartedAt,
                    now - preconnectStartedAt
                )
            }

            return preparedSession
        }

        return EarlyRealtimePreconnect(configuration: configuration, task: task)
    }

    @MainActor
    @discardableResult
    static func discard(
        _ preconnect: EarlyRealtimePreconnect?,
        onDiscarded: @escaping @MainActor (PreparedRealtimeSession) -> Void = { _ in }
    ) -> Task<Void, Never>? {
        guard let preconnect else { return nil }

        preconnect.task.cancel()
        return Task { @MainActor in
            do {
                if let preparedSession = try await preconnect.task.value {
                    preparedSession.session.cancel()
                    onDiscarded(preparedSession)
                }
            } catch {
                // Cancellation or startup failure means there is no prepared session to clean up.
            }
        }
    }

    static func configurationsMatch(
        _ lhs: TranscriptionRuntimeConfiguration,
        _ rhs: TranscriptionRuntimeConfiguration
    ) -> Bool {
        lhs.isRealtimeEnabled == rhs.isRealtimeEnabled &&
            lhs.model.name == rhs.model.name &&
            lhs.model.provider == rhs.model.provider &&
            lhs.language == rhs.language &&
            lhs.requestContext.prompt == rhs.requestContext.prompt
    }
}
