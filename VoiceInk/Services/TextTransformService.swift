import Foundation
import SwiftData

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
            let output = shared.apply(rule: rule, to: current)
            steps.append(RulePreviewStep(rule: rule, output: output, changed: output != current))
            current = output
        }

        return (steps, current)
    }

    func applyRules(to text: String, using context: ModelContext) -> String {
        let descriptor = FetchDescriptor<TextRule>(
            predicate: #Predicate { $0.isEnabled },
            sortBy: [SortDescriptor(\.dateAdded, order: .forward)]
        )

        guard let rules = try? context.fetch(descriptor), !rules.isEmpty else {
            return text
        }

        var result = text

        for rule in rules {
            result = apply(rule: rule, to: result)
        }

        return result
    }

    private func apply(rule: TextRule, to text: String) -> String {
        guard !rule.pattern.isEmpty else { return text }

        switch rule.matchMode {
        case .literal:
            return text.replacingOccurrences(of: rule.pattern, with: rule.replacement)

        case .regex:
            return applyRegex(pattern: rule.pattern, replacement: rule.replacement, to: text)
        }
    }

    private func applyRegex(pattern: String, replacement: String, to text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}
