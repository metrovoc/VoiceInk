import Foundation
import Testing
@testable import VoiceInk_CE

@MainActor
struct RecordingAudioTaskCoordinatorTests {
    @Test func cancelStartTasksPreventsDelayedMute() async {
        let coordinator = RecordingAudioTaskCoordinator()
        var didMute = false

        coordinator.scheduleMute(afterDelayNanoseconds: 20_000_000) {
            didMute = true
        }
        coordinator.cancelStartTasks()

        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(!didMute)
    }

    @Test func cancelStartTasksPreventsPendingPauseOperation() async {
        let coordinator = RecordingAudioTaskCoordinator()
        var didPause = false

        coordinator.schedulePause {
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !Task.isCancelled else { return }
            didPause = true
        }
        coordinator.cancelStartTasks()

        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(!didPause)
    }

    @Test func cancelRestorationPreventsResumeAfterUnmuteCompletes() async {
        let coordinator = RecordingAudioTaskCoordinator()
        var didUnmute = false
        var didResume = false

        coordinator.restoreAudio(
            unmute: {
                didUnmute = true
                try? await Task.sleep(nanoseconds: 20_000_000)
            },
            resume: {
                didResume = true
            }
        )
        await Task.yield()
        coordinator.cancelRestoration()

        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(didUnmute)
        #expect(!didResume)
    }

    @Test func newerRestorationCancelsOlderResume() async {
        let coordinator = RecordingAudioTaskCoordinator()
        var resumedLabels: [String] = []

        coordinator.restoreAudio(
            unmute: {
                try? await Task.sleep(nanoseconds: 20_000_000)
            },
            resume: {
                resumedLabels.append("old")
            }
        )
        await Task.yield()

        coordinator.restoreAudio(
            unmute: {},
            resume: {
                resumedLabels.append("new")
            }
        )

        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(resumedLabels == ["new"])
    }
}
