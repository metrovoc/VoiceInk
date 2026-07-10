import Foundation

/// Immutable, Sendable input for post-transcription CPU work. SwiftData and
/// UserDefaults are snapshotted before this value is created; processing can
/// therefore run without MainActor or model-context access.
struct TranscriptionTextProcessingInput: Sendable {
    let text: String
    let fillerWords: [String]
    let formatsParagraphs: Bool
    let wordReplacements: [WordReplacementRuleSnapshot]
    let textRules: [TextRuleSnapshot]
    let punctuationMode: PunctuationCleanupMode
    let lowercasesText: Bool
}

struct TranscriptionTextProcessingResult: Sendable, Equatable {
    /// Text used for prompt detection and AI enhancement, matching the legacy
    /// ordering before final punctuation/lowercase cleanup.
    let transformedText: String
    let cleanedText: String
    let wordCount: Int
}

enum TranscriptionTextProcessor {
    static func process(
        _ input: TranscriptionTextProcessingInput
    ) -> TranscriptionTextProcessingResult {
        var text = TranscriptionOutputFilter.filter(
            input.text,
            fillerWords: input.fillerWords
        )
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if input.formatsParagraphs {
            text = ParagraphFormatter.format(text)
        }

        text = WordReplacementService.applyReplacements(
            to: text,
            rules: input.wordReplacements
        )
        text = TextTransformService.applyRules(to: text, rules: input.textRules)

        let cleanedText = TranscriptionOutputFilter.applyCleanupPreferences(
            text,
            punctuationMode: input.punctuationMode,
            shouldLowercase: input.lowercasesText
        )

        return TranscriptionTextProcessingResult(
            transformedText: text,
            cleanedText: cleanedText,
            wordCount: WordCounter.count(in: text)
        )
    }
}
