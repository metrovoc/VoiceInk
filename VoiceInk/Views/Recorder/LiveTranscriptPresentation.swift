import AppKit
import SwiftUI

struct LiveTranscriptTextEdit: Equatable {
    let range: NSRange
    let replacement: String

    func applying(to source: String) -> String {
        let result = NSMutableString(string: source)
        result.replaceCharacters(in: range, with: replacement)
        return result as String
    }
}

/// Finds the smallest UTF-16 replacement that transforms one transcript
/// snapshot into another. NSTextStorage can then invalidate only the changed
/// glyph range instead of rebuilding and laying out the entire transcript.
enum LiveTranscriptTextEditPlanner {
    static func edit(from oldText: String, to newText: String) -> LiveTranscriptTextEdit? {
        guard oldText != newText else { return nil }

        let old = oldText as NSString
        let new = newText as NSString
        let sharedLength = min(old.length, new.length)
        var commonPrefixLength = 0

        while commonPrefixLength < sharedLength,
              old.character(at: commonPrefixLength) == new.character(at: commonPrefixLength) {
            commonPrefixLength += 1
        }

        // Do not leave half of a surrogate pair on either side of the edit.
        if commonPrefixLength > 0,
           commonPrefixLength < old.length,
           commonPrefixLength < new.length,
           isHighSurrogate(old.character(at: commonPrefixLength - 1)) {
            commonPrefixLength -= 1
        }

        var commonSuffixLength = 0
        let oldRemaining = old.length - commonPrefixLength
        let newRemaining = new.length - commonPrefixLength
        while commonSuffixLength < oldRemaining,
              commonSuffixLength < newRemaining,
              old.character(at: old.length - commonSuffixLength - 1)
                == new.character(at: new.length - commonSuffixLength - 1) {
            commonSuffixLength += 1
        }

        // A shared suffix can begin at a low surrogate when two valid scalar
        // values have different high surrogates but the same low surrogate.
        // Keep the complete pair inside the replacement range.
        if commonSuffixLength > 0 {
            let oldSuffixStart = old.length - commonSuffixLength
            let newSuffixStart = new.length - commonSuffixLength
            if isLowSurrogate(old.character(at: oldSuffixStart))
                || isLowSurrogate(new.character(at: newSuffixStart)) {
                commonSuffixLength -= 1
            }
        }

        let oldReplacementLength = old.length - commonPrefixLength - commonSuffixLength
        let newReplacementLength = new.length - commonPrefixLength - commonSuffixLength
        let replacement = new.substring(
            with: NSRange(location: commonPrefixLength, length: newReplacementLength)
        )

        return LiveTranscriptTextEdit(
            range: NSRange(location: commonPrefixLength, length: oldReplacementLength),
            replacement: replacement
        )
    }

    private static func isHighSurrogate(_ codeUnit: unichar) -> Bool {
        (0xD800...0xDBFF).contains(codeUnit)
    }

    private static func isLowSurrogate(_ codeUnit: unichar) -> Bool {
        (0xDC00...0xDFFF).contains(codeUnit)
    }
}

@MainActor
final class LiveTranscriptPresentationModel: ObservableObject {
    private(set) var revision: UInt64 = 0
    private(set) var previewText = ""
    private(set) var hasContent = false

    private struct JournalEntry {
        let revision: UInt64
        let edit: LiveTranscriptTextEdit
    }

    private static let journalCapacity = 128
    private var journal = Array<JournalEntry?>(repeating: nil, count: journalCapacity)
    private var sourceRevision: UInt64?
    private var committedSegments: [StreamingTranscriptSegment] = []
    private var committedUTF16Length = 0
    private var renderedUTF16Length = 0
    private var partial: String?
    private var legacyText: String?

    init(text: String = "") {
        guard !text.isEmpty else { return }
        legacyText = text
        renderedUTF16Length = (text as NSString).length
        previewText = String(text.suffix(256))
        hasContent = true
        record(
            LiveTranscriptTextEdit(
                range: NSRange(location: 0, length: 0),
                replacement: text
            )
        )
    }

    func update(text: String) {
        let current = renderedText()
        guard let edit = LiveTranscriptTextEditPlanner.edit(from: current, to: text) else { return }

        sourceRevision = nil
        committedSegments = []
        committedUTF16Length = 0
        partial = nil
        legacyText = text
        renderedUTF16Length = (text as NSString).length
        previewText = String(text.suffix(256))
        hasContent = !text.isEmpty
        record(edit)
    }

    func apply(snapshot: StreamingTranscriptSnapshot) {
        if let sourceRevision, snapshot.revision <= sourceRevision {
            return
        }

        let newlyCommitted: [StreamingTranscriptSegment]
        if let lastCommittedID = committedSegments.last?.id {
            newlyCommitted = snapshot.appendedSegments.filter { $0.id > lastCommittedID }
        } else {
            newlyCommitted = snapshot.appendedSegments
        }
        let normalizedPartial = snapshot.partial.flatMap { $0.isEmpty ? nil : $0 }

        var nextCommittedUTF16Length = committedUTF16Length
        for segment in newlyCommitted {
            if nextCommittedUTF16Length > 0 {
                nextCommittedUTF16Length += 1
            }
            nextCommittedUTF16Length += (segment.text as NSString).length
        }

        let replacement = renderTail(
            newlyCommitted: newlyCommitted[...],
            partial: normalizedPartial,
            hasCommittedPrefix: !committedSegments.isEmpty
        )
        let edit = LiveTranscriptTextEdit(
            range: NSRange(
                location: committedUTF16Length,
                length: renderedUTF16Length - committedUTF16Length
            ),
            replacement: replacement
        )
        let didContentChange = !newlyCommitted.isEmpty || self.partial != normalizedPartial

        sourceRevision = snapshot.revision
        committedSegments.append(contentsOf: newlyCommitted)
        committedUTF16Length = nextCommittedUTF16Length
        renderedUTF16Length = nextCommittedUTF16Length + (normalizedPartial.map {
            (nextCommittedUTF16Length > 0 ? 1 : 0) + ($0 as NSString).length
        } ?? 0)
        partial = normalizedPartial
        previewText = boundedPreview(
            normalizedPartial ?? newlyCommitted.last?.text ?? committedSegments.last?.text ?? ""
        )
        hasContent = !committedSegments.isEmpty || normalizedPartial != nil

        if didContentChange {
            record(edit)
        }
    }

    func clear() {
        sourceRevision = nil
        committedSegments = []
        committedUTF16Length = 0
        partial = nil
        legacyText = nil
        previewText = ""
        hasContent = false

        guard renderedUTF16Length > 0 else { return }
        let edit = LiveTranscriptTextEdit(
            range: NSRange(location: 0, length: renderedUTF16Length),
            replacement: ""
        )
        renderedUTF16Length = 0
        record(edit)
    }

    func edits(after appliedRevision: UInt64) -> [LiveTranscriptTextEdit]? {
        guard appliedRevision <= revision else { return nil }
        guard appliedRevision < revision else { return [] }
        guard revision - appliedRevision <= UInt64(Self.journalCapacity) else { return nil }

        var result: [LiveTranscriptTextEdit] = []
        result.reserveCapacity(Int(revision - appliedRevision))
        for requestedRevision in (appliedRevision + 1)...revision {
            let index = Int(requestedRevision % UInt64(Self.journalCapacity))
            guard let entry = journal[index], entry.revision == requestedRevision else {
                return nil
            }
            result.append(entry.edit)
        }
        return result
    }

    func renderedText() -> String {
        if let legacyText {
            return legacyText
        }
        var components = committedSegments.map(\.text)
        if let partial {
            components.append(partial)
        }
        return components.joined(separator: " ")
    }

    private func renderTail(
        newlyCommitted: ArraySlice<StreamingTranscriptSegment>,
        partial: String?,
        hasCommittedPrefix: Bool
    ) -> String {
        var components = newlyCommitted.map(\.text)
        if let partial {
            components.append(partial)
        }
        guard !components.isEmpty else { return "" }
        let body = components.joined(separator: " ")
        return hasCommittedPrefix ? " " + body : body
    }

    /// Recorder chrome only needs a short tail preview. Keeping this bounded is
    /// important because SwiftUI's placeholder view must never inherit the
    /// layout cost of an arbitrarily long provider hypothesis.
    private func boundedPreview(_ text: String) -> String {
        String(text.suffix(256))
    }

    private func record(_ edit: LiveTranscriptTextEdit) {
        objectWillChange.send()
        revision &+= 1
        let index = Int(revision % UInt64(Self.journalCapacity))
        journal[index] = JournalEntry(revision: revision, edit: edit)
    }
}

struct LiveTranscriptTextSurface: NSViewRepresentable {
    @ObservedObject var model: LiveTranscriptPresentationModel

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: .zero)
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesFindPanel = true
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = NSColor.white.withAlphaComponent(0.8)
        textView.textContainerInset = NSSize(width: 16, height: 6)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.layoutManager?.backgroundLayoutEnabled = false

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let textStorage = textView.textStorage else {
            return
        }

        let availableWidth = max(0, scrollView.contentSize.width)
        if textView.frame.width != availableWidth {
            textView.frame.size.width = availableWidth
            textView.textContainer?.containerSize.width = availableWidth
        }

        let appliedRevision = context.coordinator.appliedRevision
        guard appliedRevision != model.revision else {
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8)
        ]
        if let edits = model.edits(after: appliedRevision) {
            textStorage.beginEditing()
            for edit in edits {
                textStorage.replaceCharacters(
                    in: edit.range,
                    with: NSAttributedString(string: edit.replacement, attributes: attributes)
                )
            }
            textStorage.endEditing()
        } else if let recoveryEdit = LiveTranscriptTextEditPlanner.edit(
            from: textStorage.string,
            to: model.renderedText()
        ) {
            textStorage.replaceCharacters(
                in: recoveryEdit.range,
                with: NSAttributedString(string: recoveryEdit.replacement, attributes: attributes)
            )
        }

        context.coordinator.appliedRevision = model.revision
        context.coordinator.scheduleScrollToEnd(of: textView, revision: model.revision)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelPendingScroll()
    }

    @MainActor
    final class Coordinator {
        var appliedRevision: UInt64 = 0
        private var pendingScroll: Task<Void, Never>?

        func scheduleScrollToEnd(of textView: NSTextView, revision: UInt64) {
            pendingScroll?.cancel()
            pendingScroll = Task { @MainActor [weak self, weak textView] in
                await Task.yield()
                guard let self,
                      let textView,
                      !Task.isCancelled,
                      self.appliedRevision == revision else {
                    return
                }
                let end = NSRange(location: textView.textStorage?.length ?? 0, length: 0)
                textView.scrollRangeToVisible(end)
            }
        }

        func cancelPendingScroll() {
            pendingScroll?.cancel()
            pendingScroll = nil
        }
    }
}
