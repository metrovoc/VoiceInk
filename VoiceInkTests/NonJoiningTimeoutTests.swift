import Foundation
import Testing
@testable import VoiceInk_CE

struct NonJoiningTimeoutTests {
    @Test func deadlineDoesNotJoinCancellationIgnoringOperation() async {
        let startedAt = ProcessInfo.processInfo.systemUptime

        do {
            _ = try await NonJoiningTimeout.value(nanoseconds: 20_000_000) {
                NonJoiningTimeoutBlockingWork.run(for: 0.20)
                return "late"
            }
            Issue.record("Expected wall-clock timeout")
        } catch NonJoiningTimeoutError.timedOut {
            // Expected.
        } catch {
            Issue.record("Unexpected timeout error: \(error)")
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        #expect(elapsed < 0.10)
    }

    @Test func parentCancellationReturnsWithoutJoiningOperation() async {
        let task = Task {
            try await NonJoiningTimeout.value(nanoseconds: 5_000_000_000) {
                NonJoiningTimeoutBlockingWork.run(for: 0.20)
                return "late"
            }
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }

        #expect(ProcessInfo.processInfo.systemUptime - cancelledAt < 0.10)
    }
}

private enum NonJoiningTimeoutBlockingWork {
    static func run(for duration: TimeInterval) {
        Thread.sleep(forTimeInterval: duration)
    }
}
