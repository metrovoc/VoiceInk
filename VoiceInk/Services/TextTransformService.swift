import Foundation
import SwiftData

struct TextRuleSnapshot: Sendable, Equatable {
    let pattern: String
    let replacement: String
    let matchMode: MatchMode
}

struct RulePreviewStep {
    let rule: TextRule
    let output: String
    let changed: Bool
}

class TextTransformService {
    static let shared = TextTransformService()

    private init() {}

    /// Preview transformation pipeline, returning each step's result
    static func preview(input: String, rules: [TextRule]) -> (steps: [RulePreviewStep], final: String) {
        guard !input.isEmpty else { return ([], input) }

        var current = input
        var steps: [RulePreviewStep] = []

        for rule in rules where rule.isEnabled {
            let output = apply(
                rule: TextRuleSnapshot(
                    pattern: rule.pattern,
                    replacement: rule.replacement,
                    matchMode: rule.matchMode
                ),
                to: current
            )
            steps.append(RulePreviewStep(rule: rule, output: output, changed: output != current))
            current = output
        }

        return (steps, current)
    }

    func applyRules(to text: String, using context: ModelContext) -> String {
        Self.applyRules(to: text, rules: enabledRules(using: context))
    }

    func enabledRules(using context: ModelContext) -> [TextRuleSnapshot] {
        let descriptor = FetchDescriptor<TextRule>(
            predicate: #Predicate { $0.isEnabled },
            sortBy: [SortDescriptor(\.dateAdded, order: .forward)]
        )

        guard let rules = try? context.fetch(descriptor), !rules.isEmpty else {
            return []
        }

        return rules.map {
            TextRuleSnapshot(
                pattern: $0.pattern,
                replacement: $0.replacement,
                matchMode: $0.matchMode
            )
        }
    }

    static func applyRules(to text: String, rules: [TextRuleSnapshot]) -> String {
        guard !rules.isEmpty else { return text }

        var result = text

        for rule in rules {
            result = apply(rule: rule, to: result)
        }

        return result
    }

    private static func apply(rule: TextRuleSnapshot, to text: String) -> String {
        guard !rule.pattern.isEmpty else { return text }

        switch rule.matchMode {
        case .literal:
            return text.replacingOccurrences(of: rule.pattern, with: rule.replacement)

        case .regex:
            return applyRegex(pattern: rule.pattern, replacement: rule.replacement, to: text)
        }
    }

    private static func applyRegex(pattern: String, replacement: String, to text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}
