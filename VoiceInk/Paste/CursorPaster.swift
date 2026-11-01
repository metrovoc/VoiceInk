import Foundation
import AppKit
import Carbon
import os

class CursorPaster {
    private static let logger = Logger(subsystem: "com.metrovoc.voiceink", category: "CursorPaster")

    enum PasteResult: Equatable {
        case commandPosted
        case commandNotPosted
        case commandPartiallyPosted

        var didPostPasteCommand: Bool {
            self == .commandPosted
        }
    }

    private static let prePasteDelay: TimeInterval = 0.10
    private static let pasteShortcutEventDelay: TimeInterval = 0.01
    private static let minimumClipboardRestoreDelay: TimeInterval = 0.25
    @MainActor private static var pasteQueueTail: Task<Void, Never>?

    static func pasteAtCursor(_ text: String) {
        Task {
            let pasteTask = await MainActor.run {
                startPasteAtCursor(text)
            }
            _ = await pasteTask.value
        }
    }

    @MainActor
    @discardableResult
    static func startPasteAtCursor(
        _ text: String,
        autoSendKey: AutoSendKey = .none
    ) -> Task<PasteResult, Never> {
        let previous = pasteQueueTail
        let task = Task { @MainActor in
            _ = await previous?.value
            return await performPasteSession(text, autoSendKey: autoSendKey)
        }
        pasteQueueTail = Task { @MainActor in _ = await task.value }
        return task
    }

    @MainActor
    static func pasteAtCursorAndWaitUntilPosted(_ text: String) async -> PasteResult {
        await startPasteAtCursor(text).value
    }

    @MainActor
    private static func performPasteSession(
        _ text: String,
        autoSendKey: AutoSendKey
    ) async -> PasteResult {
        let method = PasteMethod.current()
        let pasteboard = method.usesClipboard ? NSPasteboard.general : nil
        let shouldRestoreClipboard = pasteboard != nil
            && UserDefaults.standard.bool(forKey: "restoreClipboardAfterPaste")
        let savedContents = shouldRestoreClipboard
            ? pasteboard.map { PasteboardSnapshot(pasteboard: $0) }
            : nil
        let sessionID = UUID().uuidString

        if pasteboard != nil {
            guard ClipboardManager.setClipboard(
                text,
                transient: shouldRestoreClipboard,
                sessionID: shouldRestoreClipboard ? sessionID : nil
            ) else {
                logger.error("Failed to prepare clipboard for paste")
                return .commandNotPosted
            }
        }

        await wait(prePasteDelay)

        let pasteResult = await postPasteCommand(
            text: text,
            method: method,
            autoSendKey: autoSendKey
        )
        if let pasteboard, let savedContents {
            scheduleClipboardRestore(
                savedContents,
                expectedText: text,
                sessionID: sessionID,
                on: pasteboard
            )
        }

        return pasteResult
    }

    @MainActor
    private static func postPasteCommand(
        text: String,
        method: PasteMethod,
        autoSendKey: AutoSendKey
    ) async -> PasteResult {
        switch method {
        case .appleScript:
            return pasteUsingAppleScript() ? .commandPosted : .commandNotPosted
        case .standard:
            return await pasteFromClipboard()
        case .directTyping:
            switch await DirectTextTyper.type(text, autoSendKey: autoSendKey) {
            case .posted:
                return .commandPosted
            case .notPosted:
                showTypingFailure("Direct Typing could not insert text. Check Accessibility access and try clipboard paste.")
                return .commandNotPosted
            case .partiallyPosted:
                showTypingFailure("Direct Typing was interrupted. Check the destination before retrying.")
                return .commandPartiallyPosted
            }
        case .remoteTyping:
            switch await RemoteTextTyper.type(text, autoSendKey: autoSendKey) {
            case .posted:
                return .commandPosted
            case .postedWithOmissions:
                NotificationManager.shared.showNotification(
                    title: String(localized: "Remote typing omitted characters unavailable on this keyboard layout."),
                    type: .warning
                )
                return .commandPartiallyPosted
            case .notPosted:
                showTypingFailure("Remote Desktop Typing could not start. Check Accessibility access, modifier keys, Caps Lock, and keyboard layout.")
                return .commandNotPosted
            case .unsupportedText:
                showTypingFailure("This text cannot be represented by the current keyboard layout. Use clipboard paste instead.")
                return .commandNotPosted
            case .partiallyPosted:
                showTypingFailure("Remote Desktop Typing was interrupted. Check the destination before retrying.")
                return .commandPartiallyPosted
            }
        }
    }

    @MainActor
    private static func showTypingFailure(_ message: String.LocalizationValue) {
        NotificationManager.shared.showNotification(
            title: String(localized: message),
            type: .error
        )
    }

    private static func scheduleClipboardRestore(
        _ savedContents: PasteboardSnapshot,
        expectedText: String,
        sessionID: String,
        on pasteboard: NSPasteboard
    ) {
        let delay = min(
            max(
                UserDefaults.standard.double(forKey: "clipboardRestoreDelay"),
                minimumClipboardRestoreDelay
            ),
            5
        )

        Task { @MainActor in
            await wait(delay)
            guard pasteboardStillOwnedByPasteSession(pasteboard, expectedText: expectedText, sessionID: sessionID) else {
                return
            }
            if !savedContents.restore(to: pasteboard) {
                logger.error("Failed to restore clipboard after paste")
            }
        }
    }

    private static func pasteboardStillOwnedByPasteSession(
        _ pasteboard: NSPasteboard,
        expectedText: String,
        sessionID: String
    ) -> Bool {
        pasteboard.string(forType: .string) == expectedText &&
            pasteboard.string(forType: ClipboardManager.pasteSessionType) == sessionID
    }

    // MARK: - AppleScript paste

    // "X – QWERTY ⌘" layouts remap to QWERTY when Command is held, so keystroke "v" resolves
    // the wrong key code. key code 9 (physical V) bypasses layout translation for those layouts.
    private static func makeScript(_ source: String) -> NSAppleScript? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.compileAndReturnError(&error)
        return script
    }

    private static let pasteScriptKeystroke = makeScript("tell application \"System Events\" to keystroke \"v\" using command down")
    private static let pasteScriptKeyCode   = makeScript("tell application \"System Events\" to key code 9 using command down")

    @MainActor
    private static var layoutSwitchesToQWERTYOnCommand: Bool {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let nameRef = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return false }
        return (Unmanaged<CFString>.fromOpaque(nameRef).takeUnretainedValue() as String).hasSuffix("⌘")
    }

    @MainActor
    private static func pasteUsingAppleScript() -> Bool {
        guard let script = layoutSwitchesToQWERTYOnCommand ? pasteScriptKeyCode : pasteScriptKeystroke else {
            logger.error("AppleScript paste script is unavailable")
            return false
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            logger.error("AppleScript paste failed: \(String(describing: error), privacy: .public)")
        }
        return error == nil
    }

    // MARK: - CGEvent paste

    // Posts Cmd+V via CGEvent without modifying the active input source.
    @MainActor
    private static func pasteFromClipboard() async -> PasteResult {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission is required to paste with simulated key events")
            return .commandNotPosted
        }

        let source = CGEventSource(stateID: .privateState)

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) else {
            logger.error("Failed to create Cmd+V keyboard events")
            return .commandNotPosted
        }

        cmdDown.flags = .maskCommand
        vDown.flags   = .maskCommand
        vUp.flags     = .maskCommand
        cmdUp.flags   = []

        cmdDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        vDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        vUp.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        cmdUp.post(tap: .cghidEventTap)

        return .commandPosted
    }

    private static func wait(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    // MARK: - Auto Send Keys

    static func performAutoSend(_ key: AutoSendKey) {
        guard key.isEnabled else { return }
        guard AXIsProcessTrusted() else { return }

        let source = CGEventSource(stateID: .privateState)
        let enterDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
        let enterUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)

        switch key {
        case .none: return
        case .enter: break
        case .shiftEnter:
            enterDown?.flags = .maskShift
            enterUp?.flags   = .maskShift
        case .commandEnter:
            enterDown?.flags = .maskCommand
            enterUp?.flags   = .maskCommand
        }

        enterDown?.post(tap: .cghidEventTap)
        enterUp?.post(tap: .cghidEventTap)
    }
}
