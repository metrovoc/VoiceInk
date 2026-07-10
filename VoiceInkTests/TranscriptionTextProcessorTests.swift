import Foundation
import Testing
@testable import VoiceInk_CE

struct TranscriptionTextProcessorTests {
    @Test func processingPreservesOrderingOffThePersistenceBoundary() {
        let result = TranscriptionTextProcessor.process(
            TranscriptionTextProcessingInput(
                text: "Um, HELLO foo.",
                fillerWords: ["um"],
                formatsParagraphs: false,
                wordReplacements: [
                    WordReplacementRuleSnapshot(
                        originalText: "hello",
                        replacementText: "VoiceInk"
                    )
                ],
                textRules: [
                    TextRuleSnapshot(
                        pattern: "foo",
                        replacement: "world",
                        matchMode: .literal
                    )
                ],
                punctuationMode: .removeTrailingPeriod,
                lowercasesText: true
            )
        )

        #expect(result.transformedText == "VoiceInk world.")
        #expect(result.cleanedText == "voiceink world")
        #expect(result.wordCount == 2)
    }

    @Test func longRuleSetProcessingIsDeterministic() {
        let rules = (0..<2_000).map {
            TextRuleSnapshot(
                pattern: "token\($0)",
                replacement: "value\($0)",
                matchMode: .literal
            )
        }
        let input = (0..<2_000).map { "token\($0)" }.joined(separator: " ")

        let first = TranscriptionTextProcessor.process(
            TranscriptionTextProcessingInput(
                text: input,
                fillerWords: [],
                formatsParagraphs: false,
                wordReplacements: [],
                textRules: rules,
                punctuationMode: .keep,
                lowercasesText: false
            )
        )
        let second = TranscriptionTextProcessor.process(
            TranscriptionTextProcessingInput(
                text: input,
                fillerWords: [],
                formatsParagraphs: false,
                wordReplacements: [],
                textRules: rules,
                punctuationMode: .keep,
                lowercasesText: false
            )
        )

        #expect(first == second)
        #expect(first.cleanedText.contains("value0"))
        #expect(first.cleanedText.contains("value1999"))
    }
}
