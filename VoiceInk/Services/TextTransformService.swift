import Foundation
import SwiftData

class TextTransformService {
    static let shared = TextTransformService()

    private init() {}

    func applyRules(to text: String, using context: ModelContext) -> String {
        let descriptor = FetchDescriptor<TextRule>(
            predicate: #Predicate { $0.isEnabled },
            sortBy: [SortDescriptor(\.priority, order: .forward)]
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

        case .literalWord:
            return applyWordBoundary(pattern: rule.pattern, replacement: rule.replacement, to: text)

        case .regex:
            return applyRegex(pattern: rule.pattern, replacement: rule.replacement, to: text)
        }
    }

    private func applyWordBoundary(pattern: String, replacement: String, to text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
        let regexPattern = "\\b\(escaped)\\b"

        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: .caseInsensitive) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    private func applyRegex(pattern: String, replacement: String, to text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}
