import Foundation

enum NonJoiningTimeoutError: Error, Equatable {
    case timedOut
}

private final class NonJoiningTimeoutRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var isResolved = false
    private var pendingResult: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func installContinuation(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            Self.resume(continuation, with: pendingResult)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func installTasks(
        operationTask: Task<Void, Never>,
        timeoutTask: Task<Void, Never>
    ) {
        lock.lock()
        if isResolved {
            lock.unlock()
            operationTask.cancel()
            timeoutTask.cancel()
        } else {
            self.operationTask = operationTask
            self.timeoutTask = timeoutTask
            lock.unlock()
        }
    }

    func resolve(with result: Result<Value, Error>) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        let operationTask = operationTask
        let timeoutTask = timeoutTask
        self.operationTask = nil
        self.timeoutTask = nil
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        if let continuation {
            Self.resume(continuation, with: result)
        }
    }

    private static func resume(
        _ continuation: CheckedContinuation<Value, Error>,
        with result: Result<Value, Error>
    ) {
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

/// Races an independently owned operation against a wall-clock deadline.
/// Resolution never joins the losing task: cancellation-ignoring system APIs
/// may finish later, but they cannot extend the caller's latency boundary.
enum NonJoiningTimeout {
    static func value<Value: Sendable>(
        nanoseconds: UInt64,
        priority: TaskPriority = .userInitiated,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = NonJoiningTimeoutRace<Value>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.installContinuation(continuation)

                let operationTask = Task.detached(priority: priority) {
                    do {
                        race.resolve(with: .success(try await operation()))
                    } catch {
                        race.resolve(with: .failure(error))
                    }
                }
                let timeoutTask = Task.detached(priority: priority) {
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                    } catch {
                        return
                    }
                    race.resolve(with: .failure(NonJoiningTimeoutError.timedOut))
                }
                race.installTasks(
                    operationTask: operationTask,
                    timeoutTask: timeoutTask
                )
            }
        } onCancel: {
            race.resolve(with: .failure(CancellationError()))
        }
    }
}
