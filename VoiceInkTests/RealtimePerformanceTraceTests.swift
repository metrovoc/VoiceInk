import Foundation
import Testing
@testable import VoiceInk_CE

@Suite(.serialized)
struct RealtimePerformanceTraceTests {
    @Test func snapshotUsesMonotonicMilestoneIntervals() {
        let trace = RealtimePerformanceTrace(sessionID: UUID())
        trace.mark(.recordingRequested, at: 10)
        trace.mark(.audioCaptureStarted, at: 10.2)
        trace.mark(.preconnectRequested, at: 10.23)
        trace.mark(.providerConnectStarted, at: 10.31)
        trace.mark(.firstPartialReceived, at: 11)
        trace.mark(.firstPartialPublished, at: 11.025)
        trace.mark(.stopRequested, at: 20)
        trace.mark(.commitRequested, at: 20.04)

        let snapshot = trace.snapshot()
        #expect(abs((snapshot.requestToPreconnect ?? 0) - 0.23) < 0.000_001)
        #expect(abs((snapshot.requestToAudioCapture ?? 0) - 0.2) < 0.000_001)
        #expect(abs((snapshot.requestToProviderConnect ?? 0) - 0.31) < 0.000_001)
        #expect(abs((snapshot.partialToPublish ?? 0) - 0.025) < 0.000_001)
        #expect(abs((snapshot.stopToCommit ?? 0) - 0.04) < 0.000_001)
    }

    @Test func duplicateMilestonesAreIdempotent() {
        let trace = RealtimePerformanceTrace()
        trace.mark(.stopRequested, at: 4)
        trace.mark(.stopRequested, at: 9)

        #expect(trace.snapshot().timestamps[.stopRequested] == 4)
    }

    @Test func concurrentMarksRemainConsistent() async {
        let trace = RealtimePerformanceTrace()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask {
                    trace.mark(.firstPartialReceived, at: TimeInterval(index))
                }
            }
        }

        #expect(trace.snapshot().timestamps[.firstPartialReceived] != nil)
        #expect(trace.snapshot().timestamps.count == 1)
    }

    @Test func localBudgetsProtectFrameAndControlPlaneLatency() {
        #expect(RealtimePerformanceBudget.mainActorDispatch <= 1.0 / 60.0)
        #expect(RealtimePerformanceBudget.recordingRequestToPreconnect <= 0.050)
        #expect(RealtimePerformanceBudget.stopRequestToCommit <= 0.050)
        #expect(RealtimePerformanceBudget.partialReceiveToPublish <= 0.050)
        #expect(RealtimePerformanceBudget.maximumStreamingQueueAge <= 0.100)
    }
}
