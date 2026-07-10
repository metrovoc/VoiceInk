import Combine
import Foundation

/// Recorder geometry observes only low-frequency lifecycle state. Transcript
/// content is delivered directly to its dedicated incremental presentation
/// model, while meter samples bypass ObservableObject entirely.
@MainActor
final class RecorderPresentationModel: ObservableObject {
    @Published private(set) var recordingState: RecordingState
    @Published private(set) var hasLiveTranscript = false
    let liveTranscript = LiveTranscriptPresentationModel()

    private var stateObserver: AnyCancellable?

    init(engine: VoiceInkEngine) {
        recordingState = engine.recordingState
        stateObserver = engine.$recordingState
            .removeDuplicates()
            .sink { [weak self] state in
                self?.recordingState = state
            }
    }

    func applyLiveTranscript(_ snapshot: StreamingTranscriptSnapshot) {
        liveTranscript.apply(snapshot: snapshot)
        let hasContent = liveTranscript.hasContent
        if hasLiveTranscript != hasContent {
            hasLiveTranscript = hasContent
        }
    }

    func clearLiveTranscript() {
        liveTranscript.clear()
        if hasLiveTranscript {
            hasLiveTranscript = false
        }
    }
}
