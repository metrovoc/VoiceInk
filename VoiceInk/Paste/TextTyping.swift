import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

enum TextTypingPlan {
    static let unicodeChunkLimit = 20

    static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func unicodeChunks(
        for text: String,
        maximumUTF16Units: Int = unicodeChunkLimit
    ) -> [[UniChar]]? {
        guard maximumUTF16Units > 0 else { return nil }
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        current.reserveCapacity(maximumUTF16Units)

        func flushCurrent() {
            guard !current.isEmpty else { return }
            chunks.append(current)
            current.removeAll(keepingCapacity: true)
        }

        for scalar in normalizeLineEndings(text).unicodeScalars {
            let value = scalar.value
            let isUnsupportedControl = (value < 0x20 || (0x7F...0x9F).contains(value))
                && value != 0x09
                && value != 0x0A
            guard !isUnsupportedControl else { return nil }

            if value == 0x09 || value == 0x0A {
                flushCurrent()
                chunks.append([value == 0x0A ? 0x0D : 0x09])
                continue
            }

            let scalarUnits = Array(String(scalar).utf16)
            guard scalarUnits.count <= maximumUTF16Units else { return nil }
            if current.count + scalarUnits.count > maximumUTF16Units {
                flushCurrent()
            }
            current.append(contentsOf: scalarUnits)
        }
        flushCurrent()
        return chunks
    }

    static func physicalKeyboardText(
        for text: String,
        canType: (Character) -> Bool
    ) -> (text: String, omittedCharacters: Bool) {
        let replacements: [Character: String] = [
            "’": "'", "‘": "'", "ʼ": "'",
            "“": "\"", "”": "\"", "„": "\"",
            "—": "-", "–": "-", "−": "-", "‑": "-", "…": "...",
            "\u{00A0}": " ", "\u{202F}": " ", "\u{2009}": " ",
            "ß": "ss", "ẞ": "SS", "æ": "ae", "Æ": "AE",
            "œ": "oe", "Œ": "OE", "ø": "o", "Ø": "O", "ł": "l", "Ł": "L",
        ]

        var output = ""
        var omittedCharacters = false
        for character in normalizeLineEndings(text) {
            if character == "\n" || character == "\t" || canType(character) {
                output.append(character)
                continue
            }

            let folded = String(character).folding(
                options: .diacriticInsensitive,
                locale: Locale(identifier: "en_US_POSIX")
            )
            let replacement = replacements[character] ?? folded
            if replacement != String(character), replacement.allSatisfy(canType) {
                output += replacement
            } else {
                omittedCharacters = true
            }
        }
        return (output, omittedCharacters)
    }
}

@MainActor
enum DirectTextTyper {
    enum Result {
        case posted
        case notPosted
        case partiallyPosted
    }

    private static let interChunkDelay: UInt64 = 10_000_000

    static func type(_ text: String, autoSendKey: AutoSendKey) async -> Result {
        guard AXIsProcessTrusted(),
              let chunks = TextTypingPlan.unicodeChunks(for: text),
              !chunks.isEmpty,
              let source = CGEventSource(stateID: .privateState) else {
            return .notPosted
        }

        for (index, chunk) in chunks.enumerated() {
            guard !Task.isCancelled,
                  let keyDown = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: CGKeyCode(kVK_Space),
                    keyDown: true
                  ),
                  let keyUp = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: CGKeyCode(kVK_Space),
                    keyDown: false
                  ) else {
                return index == 0 ? .notPosted : .partiallyPosted
            }

            keyDown.flags = chunk == [0x0D] && usesShiftForLineBreak(autoSendKey)
                ? .maskShift
                : []
            chunk.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
            }
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            if index < chunks.count - 1 {
                do {
                    try await Task.sleep(nanoseconds: interChunkDelay)
                } catch {
                    return .partiallyPosted
                }
            }
        }
        return .posted
    }

    private static func usesShiftForLineBreak(_ autoSendKey: AutoSendKey) -> Bool {
        autoSendKey == .none || autoSendKey == .enter
    }
}

@MainActor
enum RemoteTextTyper {
    enum Result {
        case posted
        case postedWithOmissions
        case notPosted
        case unsupportedText
        case partiallyPosted
    }

    private struct KeyStroke {
        let keyCode: CGKeyCode
        let needsShift: Bool
    }

    private static let interKeyDelay: UInt64 = 5_000_000
    private static let unsafeHeldModifiers: CGEventFlags = [
        .maskCommand, .maskControl, .maskAlternate, .maskAlphaShift,
    ]

    static func type(_ text: String, autoSendKey: AutoSendKey) async -> Result {
        guard AXIsProcessTrusted(),
              !Task.isCancelled,
              let source = CGEventSource(stateID: .privateState),
              let keyMap = currentKeyboardMap() else {
            return .notPosted
        }

        let prepared = TextTypingPlan.physicalKeyboardText(
            for: text,
            canType: { keyMap[$0] != nil }
        )
        guard !prepared.text.isEmpty else {
            return text.isEmpty ? .notPosted : .unsupportedText
        }

        let strokes = prepared.text.compactMap { character -> KeyStroke? in
            switch character {
            case "\n":
                return KeyStroke(
                    keyCode: CGKeyCode(kVK_Return),
                    needsShift: autoSendKey == .none || autoSendKey == .enter
                )
            case "\t":
                return KeyStroke(keyCode: CGKeyCode(kVK_Tab), needsShift: false)
            default:
                return keyMap[character]
            }
        }
        guard strokes.count == prepared.text.count else { return .unsupportedText }

        for (index, stroke) in strokes.enumerated() {
            let heldModifiers = CGEventSource.flagsState(.hidSystemState)
                .intersection(unsafeHeldModifiers)
            guard !Task.isCancelled,
                  heldModifiers.isEmpty,
                  let keyDown = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: stroke.keyCode,
                    keyDown: true
                  ),
                  let keyUp = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: stroke.keyCode,
                    keyDown: false
                  ) else {
                return index == 0 ? .notPosted : .partiallyPosted
            }

            let shiftDown = stroke.needsShift
                ? CGEvent(
                    keyboardEventSource: source,
                    virtualKey: CGKeyCode(kVK_Shift),
                    keyDown: true
                )
                : nil
            let shiftUp = stroke.needsShift
                ? CGEvent(
                    keyboardEventSource: source,
                    virtualKey: CGKeyCode(kVK_Shift),
                    keyDown: false
                )
                : nil
            guard !stroke.needsShift || (shiftDown != nil && shiftUp != nil) else {
                return index == 0 ? .notPosted : .partiallyPosted
            }

            shiftDown?.flags = .maskShift
            shiftDown?.post(tap: .cghidEventTap)
            keyDown.flags = stroke.needsShift ? .maskShift : []
            keyUp.flags = stroke.needsShift ? .maskShift : []
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            shiftUp?.post(tap: .cghidEventTap)

            if index < strokes.count - 1 {
                do {
                    try await Task.sleep(nanoseconds: interKeyDelay)
                } catch {
                    return .partiallyPosted
                }
            }
        }

        return prepared.omittedCharacters ? .postedWithOmissions : .posted
    }

    private static func currentKeyboardMap() -> [Character: KeyStroke]? {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(
                inputSource,
                kTISPropertyUnicodeKeyLayoutData
              ) else {
            return nil
        }
        let layoutData = unsafeBitCast(layoutPointer, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }

        var map: [Character: KeyStroke] = [:]
        for needsShift in [false, true] {
            for rawCode in UInt16(0)..<UInt16(128) {
                var deadKeyState: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 8)
                var length = 0
                let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
                    UCKeyTranslate(
                        layout,
                        rawCode,
                        UInt16(kUCKeyActionDown),
                        needsShift ? UInt32(shiftKey >> 8) : 0,
                        UInt32(LMGetKbdType()),
                        UInt32(kUCKeyTranslateNoDeadKeysBit),
                        &deadKeyState,
                        characters.count,
                        &length,
                        &characters
                    )
                }
                guard status == noErr, deadKeyState == 0, length > 0 else { continue }
                let translated = String(utf16CodeUnits: characters, count: length)
                guard translated.count == 1,
                      let character = translated.first,
                      !character.unicodeScalars.contains(where: {
                        CharacterSet.controlCharacters.contains($0)
                      }),
                      map[character] == nil else {
                    continue
                }
                map[character] = KeyStroke(
                    keyCode: CGKeyCode(rawCode),
                    needsShift: needsShift
                )
            }
        }
        return map
    }
}
