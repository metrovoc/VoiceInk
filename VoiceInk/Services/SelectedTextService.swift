import Foundation
import AppKit
import ApplicationServices
import os
import SelectedTextKit

/// Selected-text capture is a side lane. AX tree traversal and AppleScript
/// execution run on detached executors; only pasteboard access and the final
/// menu press enter MainActor.
enum SelectedTextService {
    private static let logger = Logger(
        subsystem: "com.metrovoc.voiceink",
        category: "SelectedTextService"
    )
    private static let menuCopyTimeoutNanoseconds: UInt64 = 120_000_000
    private static let pasteboardPollNanoseconds: UInt64 = 10_000_000
    private static let maximumMenuNodes = 2_500

    private final class AXElementBox: @unchecked Sendable {
        let element: AXUIElement

        init(_ element: AXUIElement) {
            self.element = element
        }
    }

    @MainActor
    private final class PasteboardCopyTransaction {
        private let pasteboard = NSPasteboard.general
        private let originalItems: [NSPasteboardItem]
        private let initialChangeCount: Int
        private var didRestore = false

        init() {
            originalItems = pasteboard.backupItems()
            initialChangeCount = pasteboard.changeCount
        }

        func readIfChanged() -> (changed: Bool, text: String?) {
            guard pasteboard.changeCount != initialChangeCount else {
                return (false, nil)
            }
            return (true, pasteboard.string(forType: .string))
        }

        func restore() {
            guard !didRestore else { return }
            didRestore = true
            pasteboard.clearContents()
            if !originalItems.isEmpty {
                pasteboard.writeObjects(originalItems)
            }
        }
    }

    nonisolated static func fetchSelectedText(target: RecordingContextTarget?) async -> String? {
        guard let target else { return nil }

        let isAccessibilityTrusted = await Task.detached(priority: .utility) {
            AXIsProcessTrusted()
        }.value
        guard isAccessibilityTrusted else {
            logger.debug("Accessibility is not trusted; selected text capture skipped")
            return nil
        }

        if let accessibilityText = await Task.detached(priority: .utility, operation: {
            normalized(captureSelectedTextByAccessibility(processID: target.processID))
        }).value {
            return accessibilityText
        }

        if let bundleIdentifier = target.bundleIdentifier,
           AppleScriptManager.shared.isBrowserSupportingAppleScript(bundleIdentifier) {
            do {
                if let appleScriptText = try await Task.detached(priority: .utility, operation: {
                    normalized(
                        try await AppleScriptManager.shared.getSelectedTextFromBrowser(bundleIdentifier)
                    )
                }).value {
                    return appleScriptText
                }
            } catch {
                logger.debug(
                    "AppleScript selected-text capture failed: \(error, privacy: .public)"
                )
            }
        }

        return await captureSelectedTextByMenuAction(processID: target.processID)
    }

    private nonisolated static func captureSelectedTextByMenuAction(processID: pid_t) async -> String? {
        guard let copyItem = await Task.detached(priority: .utility, operation: {
            findCopyMenuItem(processID: processID)
        }).value else {
            return nil
        }

        let transaction = await PasteboardCopyTransaction()
        let didStart = await Task.detached(priority: .utility) {
            AXUIElementPerformAction(
                copyItem.element,
                kAXPressAction as CFString
            ) == .success
        }.value
        guard didStart else {
            await transaction.restore()
            return nil
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + menuCopyTimeoutNanoseconds
        var selectedText: String?
        while DispatchTime.now().uptimeNanoseconds < deadline, !Task.isCancelled {
            let pasteboardUpdate = await transaction.readIfChanged()
            if pasteboardUpdate.changed {
                selectedText = normalized(pasteboardUpdate.text)
                break
            }

            do {
                try await Task.sleep(nanoseconds: pasteboardPollNanoseconds)
            } catch {
                break
            }
        }

        // Restoration completes before this capability becomes ready, so later
        // paste/delivery work can never observe our temporary copy payload.
        await transaction.restore()
        return selectedText
    }

    private nonisolated static func captureSelectedTextByAccessibility(processID: pid_t) -> String? {
        let application = AXUIElementCreateApplication(processID)
        guard let focusedElement = copyElementAttribute(
            kAXFocusedUIElementAttribute,
            from: application
        ) else {
            return nil
        }

        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        ) == .success else {
            return nil
        }
        return selectedValue as? String
    }

    /// Traverse the frozen target application's AX menu off MainActor. The
    /// returned element is pressed only after hopping to MainActor.
    private nonisolated static func findCopyMenuItem(processID: pid_t) -> AXElementBox? {
        let application = AXUIElementCreateApplication(processID)
        guard let menuBar = copyElementAttribute(kAXMenuBarAttribute, from: application) else {
            return nil
        }

        var queue = [menuBar]
        var index = 0
        while index < queue.count, index < maximumMenuNodes {
            let element = queue[index]
            index += 1

            if isEnabledCopyMenuItem(element) {
                return AXElementBox(element)
            }
            queue.append(contentsOf: copyElementArrayAttribute(kAXChildrenAttribute, from: element))
        }
        return nil
    }

    private nonisolated static func isEnabledCopyMenuItem(_ element: AXUIElement) -> Bool {
        let identifier = copyStringAttribute(kAXIdentifierAttribute, from: element)
        let commandCharacter = copyStringAttribute(kAXMenuItemCmdCharAttribute, from: element)
        let commandModifiers = copyIntAttribute(kAXMenuItemCmdModifiersAttribute, from: element)
        let isPlainCommandC = commandCharacter?.lowercased() == "c" &&
            // ApplicationServices exposes this C enum as an unimported macro
            // in some SDK/Swift combinations. Zero is the documented mask for
            // no modifiers beyond the default Command key.
            (commandModifiers == nil || commandModifiers == 0)
        guard identifier == "copy:" || isPlainCommandC else {
            return false
        }

        var enabledValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXEnabledAttribute as CFString,
            &enabledValue
        ) == .success else {
            return true
        }
        return (enabledValue as? Bool) ?? true
    }

    private nonisolated static func copyElementAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private nonisolated static func copyElementArrayAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == CFArrayGetTypeID() else {
            return []
        }
        return (value as? [AXUIElement]) ?? []
    }

    private nonisolated static func copyStringAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private nonisolated static func copyIntAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let number = value as? NSNumber else {
            return nil
        }
        return number.intValue
    }

    private nonisolated static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
