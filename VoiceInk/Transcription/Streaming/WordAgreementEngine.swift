import FluidAudio
import Foundation

// MARK: - Data Types

struct TimedWord {
    let text: String
    let normalizedText: String
    let startTime: Double
    let endTime: Double
    let confidence: Float

    init(text: String, startTime: Double, endTime: Double, confidence: Float = 1.0) {
        self.text = text
        self.normalizedText = Self.normalize(text)
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }

    private static func normalize(_ text: String) -> String {
        String(text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AgreementConfig {
    var transcribeIntervalSeconds: Double = 1.0
    var tokenConfirmationsNeeded: Int = 3
    var minWordsToConfirm: Int = 5
    // Passes below this threshold are shown as hypothesis but don't count toward confirmation.
    var minPassConfidence: Float = 0.15
    // All words in the last 3 positions before a sentence boundary must meet this threshold to be confirmed.
    var minWordConfidence: Float = 0.6
    /// A punctuation-free utterance must not retain audio until the 15-second
    /// Core ML input limit. Once the stable hypothesis crosses this duration,
    /// an agreed prefix is committed while a generous overlap remains mutable.
    var maximumUnconfirmedDurationSeconds: Double = 9.0
    var forcedConfirmationOverlapSeconds: Double = 3.0
}

struct AgreementResult {
    /// Mutable text that follows the last committed delta. Committed history is
    /// intentionally not reconstructed here; the streaming core owns it.
    let hypothesisText: String
    let newlyConfirmedText: String
}

// MARK: - Word Agreement Engine

final class WordAgreementEngine {

    private let config: AgreementConfig

    private var previousWords: [TimedWord] = []
    private var consecutiveAgreementCount: Int = 0
    private var isFirstPass: Bool = true

    private(set) var confirmedEndTime: Double = 0.0
    // Start time of the first unconfirmed word; used as the audio seek/trim point after confirmation.
    private(set) var hypothesisStartTime: Double = 0.0

    init(config: AgreementConfig = AgreementConfig()) {
        self.config = config
    }

    func reset() {
        previousWords = []
        consecutiveAgreementCount = 0
        isFirstPass = true
        confirmedEndTime = 0.0
        hypothesisStartTime = 0.0
    }

    // Compare current pass words against previous pass to find stable agreements.
    func processTranscriptionResult(words: [TimedWord], resultConfidence: Float = 1.0) -> AgreementResult {
        guard !words.isEmpty else {
            return makeResult(hypothesisWords: [], newlyConfirmedWords: [])
        }

        if isFirstPass {
            isFirstPass = false
            previousWords = words
            return makeResult(hypothesisWords: words, newlyConfirmedWords: [])
        }

        // Low-confidence pass: show as hypothesis but don't count toward agreement.
        if resultConfidence < config.minPassConfidence {
            consecutiveAgreementCount = 0
            previousWords = words
            return makeResult(hypothesisWords: words, newlyConfirmedWords: [])
        }

        let commonPrefix = findLongestCommonPrefix(current: words, previous: previousWords)
        previousWords = words

        if commonPrefix.count >= config.minWordsToConfirm {
            consecutiveAgreementCount += 1
        } else {
            consecutiveAgreementCount = 0
            return makeResult(hypothesisWords: words, newlyConfirmedWords: [])
        }

        guard consecutiveAgreementCount >= config.tokenConfirmationsNeeded else {
            return makeResult(hypothesisWords: words, newlyConfirmedWords: [])
        }

        let stableWords = Array(words.prefix(commonPrefix.count))
        let punctuationBoundary = applyPunctuationRule(words: stableWords)
        let retentionBoundary = applyRetentionRule(
            stableWords: stableWords,
            latestEndTime: words.last?.endTime
        )
        let confirmUpTo = max(punctuationBoundary, retentionBoundary)

        guard confirmUpTo > 0 else {
            return makeResult(hypothesisWords: words, newlyConfirmedWords: [])
        }

        // All 3 words at the confirmation boundary must meet the minimum confidence threshold.
        let boundaryWords = Array(words.prefix(confirmUpTo).suffix(3))
        let minBoundaryConfidence = boundaryWords.map(\.confidence).min() ?? 1.0
        guard minBoundaryConfidence >= config.minWordConfidence else {
            return makeResult(hypothesisWords: words, newlyConfirmedWords: [])
        }

        let newlyConfirmed = Array(words.prefix(confirmUpTo))
        let hypothesis = Array(words.dropFirst(confirmUpTo))

        if let lastConfirmed = newlyConfirmed.last {
            confirmedEndTime = lastConfirmed.endTime
        }

        hypothesisStartTime = hypothesis.first?.startTime ?? confirmedEndTime

        // Remaining hypothesis words already appeared in this pass, so start their count at 1.
        consecutiveAgreementCount = hypothesis.isEmpty ? 0 : 1
        previousWords = hypothesis
        isFirstPass = hypothesis.isEmpty

        return makeResult(hypothesisWords: hypothesis, newlyConfirmedWords: newlyConfirmed)
    }

    // MARK: - Token-to-Word Merging

    // Merge SentencePiece sub-word tokens into whole words. Tokens starting with `▁` mark boundaries.
    static func mergeTokensToWords(_ timings: [TokenTiming], timeOffset: Double = 0.0) -> [TimedWord] {
        guard !timings.isEmpty else { return [] }

        var words: [TimedWord] = []
        var currentText = ""
        var wordStart = 0.0
        var wordEnd = 0.0
        var currentConfidences: [Float] = []

        for timing in timings {
            let token = timing.token

            if token.hasPrefix("▁") || token.hasPrefix(" ") {
                if !currentText.isEmpty {
                    let avgConfidence = currentConfidences.isEmpty ? 1.0 :
                        currentConfidences.reduce(0, +) / Float(currentConfidences.count)
                    words.append(TimedWord(
                        text: currentText,
                        startTime: wordStart + timeOffset,
                        endTime: wordEnd + timeOffset,
                        confidence: avgConfidence
                    ))
                }
                let stripped = token.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "▁", with: "")
                currentText = stripped
                wordStart = timing.startTime
                wordEnd = timing.endTime
                currentConfidences = [timing.confidence]
            } else {
                if currentText.isEmpty {
                    wordStart = timing.startTime
                }
                currentText += token
                wordEnd = timing.endTime
                currentConfidences.append(timing.confidence)
            }
        }

        if !currentText.isEmpty {
            let avgConfidence = currentConfidences.isEmpty ? 1.0 :
                currentConfidences.reduce(0, +) / Float(currentConfidences.count)
            words.append(TimedWord(
                text: currentText,
                startTime: wordStart + timeOffset,
                endTime: wordEnd + timeOffset,
                confidence: avgConfidence
            ))
        }

        return words
    }

    // MARK: - Private

    private func findLongestCommonPrefix(current: [TimedWord], previous: [TimedWord]) -> [TimedWord] {
        let minCount = min(current.count, previous.count)
        var prefixLength = 0

        for i in 0..<minCount {
            if current[i].normalizedText == previous[i].normalizedText {
                prefixLength = i + 1
            } else {
                break
            }
        }

        return Array(current.prefix(prefixLength))
    }

    // Confirms at sentence boundaries; needs 3 enders, keeps last 2 sentences as hypothesis.
    private func applyPunctuationRule(words: [TimedWord]) -> Int {
        guard !words.isEmpty else { return 0 }

        let sentenceEnders: Set<Character> = [".", "!", "?", ";"]

        var punctuationIndices: [Int] = []
        for i in 0..<words.count {
            if let lastChar = words[i].text.last, sentenceEnders.contains(lastChar) {
                punctuationIndices.append(i)
            }
        }

        // Need at least 3 sentence enders — the latest 2 sentences always stay as hypothesis
        guard punctuationIndices.count >= 3 else { return 0 }

        let cutIndex = punctuationIndices[punctuationIndices.count - 3]

        let confirmCount = cutIndex + 1

        // Require minimum word count to avoid confirming tiny fragments
        guard confirmCount >= config.minWordsToConfirm else { return 0 }

        return confirmCount
    }

    /// Forces only an already-agreed prefix across the commit boundary. This
    /// is not lossy windowing: the most recent overlap remains hypothesis, and
    /// words that have not survived the normal agreement count are never
    /// committed. Its sole purpose is to keep the unconfirmed PCM tail bounded
    /// for arbitrarily long run-on speech without falling back at 15 seconds.
    private func applyRetentionRule(
        stableWords: [TimedWord],
        latestEndTime: Double?
    ) -> Int {
        guard config.maximumUnconfirmedDurationSeconds > 0,
              config.forcedConfirmationOverlapSeconds >= 0,
              let latestEndTime,
              latestEndTime - confirmedEndTime >= config.maximumUnconfirmedDurationSeconds else {
            return 0
        }

        let retainAfter = latestEndTime - config.forcedConfirmationOverlapSeconds
        guard let lastSafeIndex = stableWords.lastIndex(where: { $0.endTime <= retainAfter }) else {
            return 0
        }
        let count = lastSafeIndex + 1
        return count >= config.minWordsToConfirm ? count : 0
    }

    private func makeResult(hypothesisWords: [TimedWord], newlyConfirmedWords: [TimedWord]) -> AgreementResult {
        let hypothesisText = hypothesisWords.map(\.text).joined(separator: " ")
        let newlyConfirmedText = newlyConfirmedWords.map(\.text).joined(separator: " ")

        return AgreementResult(
            hypothesisText: hypothesisText,
            newlyConfirmedText: newlyConfirmedText
        )
    }
}
