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

    @Test func wordReplacementsDoNotMatchInsideUnicodeWords() {
        let result = WordReplacementService.applyReplacements(
            to: "Please do not change vergrößern, but change ERN.",
            rules: [
                WordReplacementRuleSnapshot(
                    originalText: "ERN",
                    replacementText: "EAN"
                )
            ]
        )

        #expect(result == "Please do not change vergrößern, but change EAN.")
    }

    @Test func wordReplacementsKeepPunctuationAndNonSpacedScriptBoundaries() {
        let result = WordReplacementService.applyReplacements(
            to: "Use c++ near 日本fooไทย.",
            rules: [
                WordReplacementRuleSnapshot(
                    originalText: "c++, foo",
                    replacementText: "token"
                )
            ]
        )

        #expect(result == "Use token near 日本tokenไทย.")
    }
}
