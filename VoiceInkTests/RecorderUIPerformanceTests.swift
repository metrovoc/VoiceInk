import Foundation
import Testing
@testable import VoiceInk_CE

@MainActor
struct RecorderUIPerformanceTests {
    @Test func audioMeterSourceKeepsOnlyLatestSample() {
        let source = AudioMeterSource()

        for value in 0..<10_000 {
            source.store(
                AudioMeter(
                    averagePower: Double(value),
                    peakPower: Double(value + 1)
                )
            )
        }

        let snapshot = source.snapshot()
        #expect(snapshot.sequence == 10_000)
        #expect(snapshot.meter == AudioMeter(averagePower: 9_999, peakPower: 10_000))
    }

    @Test func meterProducerAndRendererUseSixtyHertzCadence() {
        #expect(AudioMeterCadence.framesPerSecond == 60)
        #expect(abs(AudioMeterCadence.interval - (1.0 / 60.0)) < 0.000_001)
        #expect(AudioMeterCadence.intervalNanoseconds == 16_666_666)
    }

    @Test func visualizerStoreResetsImmediatelyWhenInactive() {
        let source = AudioMeterSource()
        let store = AudioVisualizerMeterStore()
        source.store(AudioMeter(averagePower: -30, peakPower: -18))

        let active = store.snapshot(from: source, isActive: true, at: 1)
        let inactive = store.snapshot(from: source, isActive: false, at: 1.01)

        #expect(active.level > 0)
        #expect(inactive == .silent)
        #expect(store.visualMeter == .silent)
        #expect(store.state.envelope == 0)
    }

    @Test func visualEnvelopeIsCadenceIndependent() {
        func run(cadence: Double) -> AudioVisualizerMeterSnapshot {
            var state = AudioVisualizerMeterState()
            let interval = 1.0 / cadence
            for tick in 0...Int(cadence) {
                _ = state.update(
                    averageDb: -70,
                    peakDb: -67,
                    at: Double(tick) * interval
                )
            }
            var snapshot = AudioVisualizerMeterSnapshot.silent
            let speechStart = Int(cadence) + 1
            let speechEnd = speechStart + Int(cadence / 2)
            for tick in speechStart...speechEnd {
                snapshot = state.update(
                    averageDb: -30,
                    peakDb: -18,
                    at: Double(tick) * interval
                )
            }
            return snapshot
        }

        let thirtyHertz = run(cadence: 30)
        let sixtyHertz = run(cadence: 60)
        #expect(abs(thirtyHertz.level - sixtyHertz.level) < 0.02)
        #expect(thirtyHertz.isSpeechActive == sixtyHertz.isSpeechActive)
    }

    @Test func structuredTranscriptReplacesOnlyMutableTail() throws {
        let model = LiveTranscriptPresentationModel()
        let hello = StreamingTranscriptSegment(id: 1, text: "hello")
        let world = StreamingTranscriptSegment(id: 2, text: "world")
        var rendered = ""
        var appliedRevision: UInt64 = 0

        model.apply(
            snapshot: StreamingTranscriptSnapshot(
                revision: 1,
                appendedSegments: [hello],
                partial: "wor"
            )
        )
        for edit in try #require(model.edits(after: appliedRevision)) {
            rendered = edit.applying(to: rendered)
        }
        appliedRevision = model.revision
        #expect(rendered == "hello wor")

        model.apply(
            snapshot: StreamingTranscriptSnapshot(
                revision: 2,
                appendedSegments: [],
                partial: "world"
            )
        )
        let partialEdits = try #require(model.edits(after: appliedRevision))
        let partialEdit = try #require(partialEdits.first)
        #expect(partialEdits.count == 1)
        #expect(partialEdit.range == NSRange(location: 5, length: 4))
        #expect(partialEdit.replacement == " world")
        rendered = partialEdit.applying(to: rendered)
        appliedRevision = model.revision

        model.apply(
            snapshot: StreamingTranscriptSnapshot(
                revision: 3,
                appendedSegments: [world],
                partial: "again"
            )
        )
        for edit in try #require(model.edits(after: appliedRevision)) {
            rendered = edit.applying(to: rendered)
        }

        #expect(rendered == "hello world again")
        #expect(model.previewText == "again")
        #expect(model.hasContent)
    }

    @Test func longTranscriptPartialUpdateHasBoundedReplacement() throws {
        let model = LiveTranscriptPresentationModel()
        let segments = (0..<10_000).map {
            StreamingTranscriptSegment(id: UInt64($0), text: "word\($0)")
        }
        model.apply(
            snapshot: StreamingTranscriptSnapshot(
                revision: 1,
                appendedSegments: segments,
                partial: "old tail"
            )
        )
        var rendered = model.renderedText()
        let previousRevision = model.revision

        model.apply(
            snapshot: StreamingTranscriptSnapshot(
                revision: 2,
                appendedSegments: [],
                partial: "new tail"
            )
        )

        let edits = try #require(model.edits(after: previousRevision))
        let edit = try #require(edits.first)
        #expect(edits.count == 1)
        #expect(edit.range.length == 9)
        #expect(edit.replacement == " new tail")
        #expect(edit.range.location > 80_000)
        rendered = edit.applying(to: rendered)
        #expect(rendered == segments.map(\.text).joined(separator: " ") + " new tail")
        #expect(rendered == model.renderedText())
    }

    @Test func structuredPreviewIsBoundedToChangedTail() {
        let model = LiveTranscriptPresentationModel()
        let longPartial = String(repeating: "p", count: 10_000)

        model.apply(
            snapshot: StreamingTranscriptSnapshot(
                revision: 1,
                appendedSegments: [
                    StreamingTranscriptSegment(id: 1, text: "stable")
                ],
                partial: longPartial
            )
        )

        #expect(model.previewText.count == 256)
        #expect(model.previewText == String(longPartial.suffix(256)))
    }

    @Test func transcriptClearIsOneKnownRangeDeletion() throws {
        let model = LiveTranscriptPresentationModel()
        model.apply(
            snapshot: StreamingTranscriptSnapshot(
                revision: 1,
                appendedSegments: [StreamingTranscriptSegment(id: 1, text: "complete")],
                partial: "tail"
            )
        )
        let previousRevision = model.revision

        model.clear()

        let edits = try #require(model.edits(after: previousRevision))
        let edit = try #require(edits.first)
        #expect(edit.range == NSRange(location: 0, length: 13))
        #expect(edit.replacement.isEmpty)
        #expect(!model.hasContent)
    }

    @Test func compatibilityEditPlannerPreservesExtendedGraphemes() throws {
        let old = "hello 👨‍👩‍👧‍👦 world"
        let new = "hello 👨‍👩‍👧‍👦 VoiceInk"
        let edit = try #require(LiveTranscriptTextEditPlanner.edit(from: old, to: new))

        #expect(edit.applying(to: old) == new)
    }

    @Test func compatibilityEditPlannerNeverSplitsACommonLowSurrogate() throws {
        let old = String(try #require(UnicodeScalar(0x1F600))) + " tail"
        let new = String(try #require(UnicodeScalar(0x1FA00))) + " tail"
        let edit = try #require(
            LiveTranscriptTextEditPlanner.edit(from: old, to: new)
        )

        #expect(edit.range == NSRange(location: 0, length: 2))
        #expect((edit.replacement as NSString).length == 2)
        #expect(edit.applying(to: old) == new)
    }
}
