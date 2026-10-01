import CoreGraphics
import Foundation

/// Global shortcuts are meaningful only for the active, unlocked console session.
enum UserSessionInputPolicy {
    // WindowServer exposes this established property without a public constant.
    private static let screenIsLockedKey = "CGSSessionScreenIsLocked"

    static var allowsShortcutHandling: Bool {
        guard let properties = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }

        return allowsShortcutHandling(sessionProperties: properties)
    }

    static func allowsShortcutHandling(sessionProperties: [String: Any]) -> Bool {
        guard booleanValue(sessionProperties[kCGSessionOnConsoleKey as String]) == true,
              booleanValue(sessionProperties[kCGSessionLoginDoneKey as String]) == true,
              booleanValue(sessionProperties[screenIsLockedKey]) != true else {
            return false
        }

        return true
    }

    private static func booleanValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }

        return (value as? NSNumber)?.boolValue
    }
}
