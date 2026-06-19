import AppKit
import CoreGraphics
import Foundation
import os

final class ShortcutMonitor {
    fileprivate enum EventKind {
        case keyDown
        case keyUp
        case flagsChanged
    }

    private struct ShortcutState {
        var shortcut: Shortcut
        var isDown = false
        var pressedAt: TimeInterval?
        var isInterrupted = false
    }

    private var shortcuts: [ShortcutAction: ShortcutState] = [:]
    private var interruptibleActions: Set<ShortcutAction> = []
    private var onKeyDown: ((ShortcutAction, TimeInterval) -> Void)?
    private var onKeyUp: ((ShortcutAction, TimeInterval) -> Void)?
    private var onEventTapKeyDown: ((ShortcutAction, TimeInterval) -> Void)?
    private var onEventTapKeyUp: ((ShortcutAction, TimeInterval, TimeInterval?) -> Void)?
    private var onShortcutInterrupted: ((ShortcutAction, TimeInterval) -> Void)?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var eventTapRunLoop: CFRunLoop?
    private var eventTapThread: Thread?
    private let stateLock = NSRecursiveLock()
    private var generation = 0
    private let logger = Logger(subsystem: "com.metrovoc.voiceink", category: "ShortcutMonitor")

    private static let shortcutInterruptionWindow: TimeInterval = 1.0

    deinit {
        stop()
    }

    @discardableResult
    func start(
        shortcuts: [ShortcutAction: Shortcut],
        interruptibleActions: Set<ShortcutAction> = [],
        onKeyDown: @escaping (ShortcutAction, TimeInterval) -> Void,
        onKeyUp: @escaping (ShortcutAction, TimeInterval) -> Void,
        onEventTapKeyDown: ((ShortcutAction, TimeInterval) -> Void)? = nil,
        onEventTapKeyUp: ((ShortcutAction, TimeInterval, TimeInterval?) -> Void)? = nil,
        onShortcutInterrupted: ((ShortcutAction, TimeInterval) -> Void)? = nil
    ) -> Bool {
        stop()

        stateLock.lock()
        generation += 1
        for (action, shortcut) in shortcuts {
            self.shortcuts[action] = ShortcutState(shortcut: shortcut)
        }

        guard !self.shortcuts.isEmpty else {
            stateLock.unlock()
            return true
        }

        self.interruptibleActions = interruptibleActions
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
        self.onEventTapKeyDown = onEventTapKeyDown
        self.onEventTapKeyUp = onEventTapKeyUp
        self.onShortcutInterrupted = onShortcutInterrupted
        stateLock.unlock()

        return installEventTap()
    }

    func stop() {
        stateLock.lock()
        generation += 1
        shortcuts = [:]
        interruptibleActions = []
        onKeyDown = nil
        onKeyUp = nil
        onEventTapKeyDown = nil
        onEventTapKeyUp = nil
        onShortcutInterrupted = nil
        stateLock.unlock()

        let runLoopToStop = eventTapRunLoop
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        if let runLoopToStop {
            CFRunLoopStop(runLoopToStop)
        }

        if let eventTapRunLoopSource {
            self.eventTapRunLoopSource = nil
        }

        eventTapRunLoop = nil
        eventTapThread = nil
    }

    private func installEventTap() -> Bool {
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                let reason = type == .tapDisabledByTimeout ? "timeout" : "userInput"
                monitor.logger.warning("Global shortcut event tap disabled reason=\(reason, privacy: .public); resetting shortcut state")
                monitor.resetPressedShortcutsAfterTapInterruption()
                if let eventTap = monitor.eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let shouldSuppress = monitor.handleCGEvent(type: type, event: event)
            return shouldSuppress ? nil : Unmanaged.passUnretained(event)
        }

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("Failed to install global shortcut event tap")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            logger.error("Failed to create global shortcut event tap run loop source")
            return false
        }

        self.eventTap = eventTap
        eventTapRunLoopSource = source
        return startEventTapThread(source: source, eventTap: eventTap)
    }

    private func startEventTapThread(source: CFRunLoopSource, eventTap: CFMachPort) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else {
                semaphore.signal()
                return
            }

            Thread.current.name = "com.metrovoc.voiceink.shortcut-monitor"
            Thread.current.qualityOfService = .userInteractive

            let runLoop = CFRunLoopGetCurrent()
            self.eventTapRunLoop = runLoop
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            semaphore.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }

        thread.name = "com.metrovoc.voiceink.shortcut-monitor"
        thread.qualityOfService = .userInteractive
        eventTapThread = thread
        thread.start()

        let result = semaphore.wait(timeout: .now() + .seconds(2))
        if result == .timedOut {
            CFMachPortInvalidate(eventTap)
            eventTapThread = nil
            eventTapRunLoop = nil
            eventTapRunLoopSource = nil
            self.eventTap = nil
            logger.error("Timed out starting global shortcut event tap thread")
            return false
        }

        return true
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard let eventKind = EventKind(type) else {
            return false
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        stateLock.lock()
        defer { stateLock.unlock() }
        return handleEvent(
            kind: eventKind,
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            eventTime: ProcessInfo.processInfo.systemUptime
        )
    }

    private func resetPressedShortcutsAfterTapInterruption() {
        let eventTime = ProcessInfo.processInfo.systemUptime
        stateLock.lock()
        defer { stateLock.unlock() }
        let pressedActions = shortcuts.compactMap { action, state in
            state.isDown ? action : nil
        }

        guard !pressedActions.isEmpty else {
            return
        }

        for action in pressedActions {
            if var state = shortcuts[action] {
                let pressDuration = state.pressedAt.map { eventTime - $0 }
                state.isDown = false
                state.pressedAt = nil
                state.isInterrupted = false
                shortcuts[action] = state
                dispatchKeyUp(for: action, eventTime: eventTime, pressDuration: pressDuration)
            } else {
                dispatchKeyUp(for: action, eventTime: eventTime, pressDuration: nil)
            }
        }
    }

    private func handleEvent(
        kind: EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventTime: TimeInterval
    ) -> Bool {
        var shouldSuppress = false

        if kind == .keyDown {
            handleShortcutInterruptions(keyCode: keyCode, eventTime: eventTime)
        }

        for action in Array(shortcuts.keys) {
            guard var state = shortcuts[action] else {
                continue
            }

            if state.shortcut.isModifierOnly {
                handleModifierOnlyShortcut(
                    action: action,
                    state: state,
                    kind: kind,
                    keyCode: keyCode,
                    modifierFlags: modifierFlags,
                    eventTime: eventTime
                )
                continue
            }

            let transition = transitionForKeyShortcut(
                state.shortcut,
                isDown: state.isDown,
                kind: kind,
                keyCode: keyCode,
                modifierFlags: modifierFlags
            )

            switch transition {
            case .none:
                break
            case .suppress:
                shouldSuppress = true
            case .keyDown:
                state.isDown = true
                state.pressedAt = eventTime
                state.isInterrupted = false
                shortcuts[action] = state
                shouldSuppress = true
                dispatchKeyDown(for: action, eventTime: eventTime)
            case .keyUp:
                let pressDuration = state.pressedAt.map { eventTime - $0 }
                state.isDown = false
                state.pressedAt = nil
                state.isInterrupted = false
                shortcuts[action] = state
                shouldSuppress = true
                dispatchKeyUp(for: action, eventTime: eventTime, pressDuration: pressDuration)
            }
        }

        return shouldSuppress
    }

    private enum ShortcutTransition {
        case none
        case suppress
        case keyDown
        case keyUp
    }

    private func transitionForKeyShortcut(
        _ shortcut: Shortcut,
        isDown: Bool,
        kind: EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ShortcutTransition {
        switch kind {
        case .keyDown:
            guard shortcut.matchesKeyEvent(keyCode: keyCode, modifierFlags: modifierFlags) else {
                return .none
            }

            return isDown ? .suppress : .keyDown
        case .keyUp:
            return isDown && keyCode == shortcut.keyCode ? .keyUp : .none
        case .flagsChanged:
            guard isDown else {
                return .none
            }

            let currentFlags = Shortcut.normalizedModifierFlags(
                modifierFlags,
                forKeyCode: shortcut.keyCode
            )
            return currentFlags.isSuperset(of: shortcut.modifierFlags) ? .suppress : .keyUp
        }
    }

    private func handleModifierOnlyShortcut(
        action: ShortcutAction,
        state: ShortcutState,
        kind: EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventTime: TimeInterval
    ) {
        var state = state

        guard kind == .flagsChanged else {
            return
        }

        if state.isDown {
            if state.shortcut.shouldReleaseModifierEvent(keyCode: keyCode, modifierFlags: modifierFlags) {
                let pressDuration = state.pressedAt.map { eventTime - $0 }
                state.isDown = false
                state.pressedAt = nil
                state.isInterrupted = false
                shortcuts[action] = state
                dispatchKeyUp(for: action, eventTime: eventTime, pressDuration: pressDuration)
            }

            return
        }

        if state.shortcut.matchesModifierEvent(keyCode: keyCode, modifierFlags: modifierFlags) {
            state.isDown = true
            state.pressedAt = eventTime
            state.isInterrupted = false
            shortcuts[action] = state
            dispatchKeyDown(for: action, eventTime: eventTime)
        }
    }

    private func handleShortcutInterruptions(keyCode: UInt16, eventTime: TimeInterval) {
        guard !Shortcut.isModifierKeyCode(keyCode) else {
            return
        }

        for action in interruptibleActions {
            guard var state = shortcuts[action],
                  state.isDown,
                  !state.isInterrupted,
                  let pressedAt = state.pressedAt,
                  eventTime - pressedAt <= Self.shortcutInterruptionWindow,
                  state.shortcut.isInterruptedByAdditionalKeyDown(keyCode: keyCode)
            else {
                continue
            }

            state.isInterrupted = true
            shortcuts[action] = state
            dispatchShortcutInterrupted(for: action, eventTime: eventTime)
        }
    }

    private func dispatchKeyDown(for action: ShortcutAction, eventTime: TimeInterval) {
        onEventTapKeyDown?(action, eventTime)
        let callback = onKeyDown
        let generation = generation
        DispatchQueue.main.async { [weak self, callback] in
            guard self?.isCurrentGeneration(generation) == true else { return }
            self?.logMainDispatchDelay(kind: "keyDown", action: action, eventTime: eventTime)
            callback?(action, eventTime)
        }
    }

    private func dispatchKeyUp(for action: ShortcutAction, eventTime: TimeInterval, pressDuration: TimeInterval?) {
        onEventTapKeyUp?(action, eventTime, pressDuration)
        let callback = onKeyUp
        let generation = generation
        DispatchQueue.main.async { [weak self, callback] in
            guard self?.isCurrentGeneration(generation) == true else { return }
            callback?(action, eventTime)
        }
    }

    private func dispatchShortcutInterrupted(for action: ShortcutAction, eventTime: TimeInterval) {
        let callback = onShortcutInterrupted
        let generation = generation
        DispatchQueue.main.async { [weak self, callback] in
            guard self?.isCurrentGeneration(generation) == true else { return }
            callback?(action, eventTime)
        }
    }

    private func logMainDispatchDelay(kind: String, action: ShortcutAction, eventTime: TimeInterval) {
        let delay = ProcessInfo.processInfo.systemUptime - eventTime
        guard delay > 0.050 else { return }
        logger.notice("Shortcut \(kind, privacy: .public) main dispatch delay action=\(action.storageName, privacy: .public) elapsed=\(delay, format: .fixed(precision: 3), privacy: .public)s")
    }

    private func isCurrentGeneration(_ generation: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return self.generation == generation
    }

    private static let eventMask: CGEventMask = [
        CGEventType.keyDown,
        CGEventType.keyUp,
        CGEventType.flagsChanged
    ].reduce(CGEventMask(0)) { mask, type in
        mask | (CGEventMask(1) << Int(type.rawValue))
    }
}

private extension ShortcutMonitor.EventKind {
    init?(_ type: CGEventType) {
        switch type {
        case .keyDown:
            self = .keyDown
        case .keyUp:
            self = .keyUp
        case .flagsChanged:
            self = .flagsChanged
        default:
            return nil
        }
    }
}
