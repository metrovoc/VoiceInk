import Foundation
import SwiftData

enum MatchMode: String, Codable, CaseIterable {
    case literal = "Literal"
    case literalWord = "Whole Word"
    case regex = "Regex"
}

@Model
final class TextRule {
    var id: UUID
    var pattern: String
    var replacement: String
    var matchMode: MatchMode
    var isEnabled: Bool
    var priority: Int
    var dateAdded: Date

    init(
        pattern: String,
        replacement: String = "",
        matchMode: MatchMode = .literal,
        isEnabled: Bool = true,
        priority: Int = 0
    ) {
        self.id = UUID()
        self.pattern = pattern
        self.replacement = replacement
        self.matchMode = matchMode
        self.isEnabled = isEnabled
        self.priority = priority
        self.dateAdded = Date()
    }
}
