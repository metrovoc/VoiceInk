import SwiftUI
import AppKit
import OSLog

enum MainWindowLifecyclePolicy {
    static func shouldHideInsteadOfClose(
        windowIdentifier: NSUserInterfaceItemIdentifier?,
        mainIdentifier: NSUserInterfaceItemIdentifier
    ) -> Bool {
        windowIdentifier == mainIdentifier
    }

    static func shouldRestoreAccessoryPolicy(
        isMenuBarOnly: Bool,
        hasVisibleNormalWindows: Bool,
        currentPolicy: NSApplication.ActivationPolicy
    ) -> Bool {
        isMenuBarOnly && !hasVisibleNormalWindows && currentPolicy != .accessory
    }
}

class WindowManager: NSObject {
    static let shared = WindowManager()

    private static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("com.metrovoc.voiceink.mainWindow")
    private static let mainWindowAutosaveName = NSWindow.FrameAutosaveName("VoiceInkMainWindowFrame")

    private let logger = Logger(subsystem: "com.metrovoc.voiceink", category: "WindowManager")
    private var mainWindow: NSWindow?
    private var didApplyInitialPlacement = false

    private override init() {
        super.init()
    }
    
    func configureWindow(_ window: NSWindow) {
        if let existingWindow = NSApplication.shared.windows.first(where: { $0.identifier == Self.mainWindowIdentifier && $0 != window }) {
            logger.notice("configureWindow: duplicate detected, reusing existing window")
            window.close()
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }
        logger.notice("configureWindow: registering main window")
        
        let requiredStyleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.styleMask.formUnion(requiredStyleMask)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.title = AppIdentity.displayName
        window.collectionBehavior = [.fullScreenPrimary]
        window.level = .normal
        window.isOpaque = false
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 0, height: 0)
        window.setFrameAutosaveName(Self.mainWindowAutosaveName)
        applyInitialPlacementIfNeeded(to: window)
        registerMainWindowIfNeeded(window)
        window.orderFrontRegardless()
    }
    
    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
        window.identifier = Self.mainWindowIdentifier
        window.delegate = self
    }
    
    func showMainWindow() -> NSWindow? {
        guard let window = resolveMainWindow() else {
            return nil
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return window
    }
    
    func hideMainWindow() {
        guard let window = resolveMainWindow() else {
            return
        }
        window.orderOut(nil)
        restoreAccessoryPolicyIfNeededAfterWindowHide()
    }
    
    func currentMainWindow() -> NSWindow? {
        resolveMainWindow()
    }
    
    private func registerMainWindowIfNeeded(_ window: NSWindow) {
        // Only register the primary content window, identified by the hidden title bar style
        if window.identifier == nil || window.identifier != Self.mainWindowIdentifier {
            registerMainWindow(window)
        }
    }
    
    private func applyInitialPlacementIfNeeded(to window: NSWindow) {
        guard !didApplyInitialPlacement else { return }
        // Attempt to restore previous frame if one exists; otherwise fall back to a centered placement
        if !window.setFrameUsingName(Self.mainWindowAutosaveName) {
            window.center()
        }
        didApplyInitialPlacement = true
    }
    
    private func resolveMainWindow() -> NSWindow? {
        if let window = mainWindow {
            return window
        }

        logger.notice("resolveMainWindow: weak ref is nil, searching \(NSApplication.shared.windows.count, privacy: .public) windows by identifier")

        if let window = NSApplication.shared.windows.first(where: { $0.identifier == Self.mainWindowIdentifier }) {
            logger.notice("resolveMainWindow: recovered window via identifier fallback")
            mainWindow = window
            window.delegate = self
            return window
        }

        let windowIDs = NSApplication.shared.windows.map { $0.identifier?.rawValue ?? "nil" }.joined(separator: ", ")
        logger.error("resolveMainWindow: FAILED — no window found with main identifier. Total windows: \(NSApplication.shared.windows.count, privacy: .public), identifiers: \(windowIDs, privacy: .public)")
        return nil
    }

    private func restoreAccessoryPolicyIfNeededAfterWindowHide() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let hasVisibleWindows = NSApplication.shared.windows.contains {
                $0.isVisible && $0.level == .normal && !$0.styleMask.contains(.nonactivatingPanel)
            }

            if MainWindowLifecyclePolicy.shouldRestoreAccessoryPolicy(
                isMenuBarOnly: UserDefaults.standard.bool(forKey: "IsMenuBarOnly"),
                hasVisibleNormalWindows: hasVisibleWindows,
                currentPolicy: NSApplication.shared.activationPolicy()
            ) {
                NSApplication.shared.setActivationPolicy(.accessory)
            }
        }
    }
}

extension WindowManager: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard MainWindowLifecyclePolicy.shouldHideInsteadOfClose(
            windowIdentifier: sender.identifier,
            mainIdentifier: Self.mainWindowIdentifier
        ) else {
            return true
        }

        logger.notice("windowShouldClose: hiding main window instead of closing")
        sender.orderOut(nil)
        restoreAccessoryPolicyIfNeededAfterWindowHide()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window.identifier == Self.mainWindowIdentifier {
            logger.notice("windowWillClose: main window closing, clearing weak reference")
            window.orderOut(nil)
            mainWindow = nil
            didApplyInitialPlacement = false
        }
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier == Self.mainWindowIdentifier else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
} 
