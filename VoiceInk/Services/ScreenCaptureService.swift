import Foundation
import AppKit
import Vision
import ScreenCaptureKit
import ApplicationServices

private enum ScreenCaptureGeometry {
    static let maximumDimension: CGFloat = 2800
    static let focusedWindowFrameTolerance: CGFloat = 96
}

@MainActor
class ScreenCaptureService: ObservableObject {
    @Published var isCapturing = false
    @Published var lastCapturedText: String?

    private static let captureTimeout: TimeInterval = 3.0

    static func requestScreenCapturePermissionRegistration() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        if CGRequestScreenCaptureAccess() {
            return true
        }

        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            return CGPreflightScreenCaptureAccess()
        }

        return CGPreflightScreenCaptureAccess()
    }

    func captureAndExtractText() async -> String? {
        guard !isCapturing else { return nil }

        isCapturing = true
        defer {
            isCapturing = false
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let focusedWindowHint = makeFocusedWindowHint(excluding: currentPID)

        guard let focusedWindowHint,
              let contextText = await Self.captureAndExtractText(
                focusedWindowHint: focusedWindowHint,
                currentPID: currentPID
              ) else {
            return nil
        }

        lastCapturedText = contextText
        return contextText
    }

    /// Freeze only the AppKit-owned frontmost process identity on MainActor.
    /// Focused-window AX traversal is enriched later on the capture side lane.
    private func makeFocusedWindowHint(excluding currentPID: pid_t) -> RecordingContextWindowHint? {
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontmostPID != currentPID else {
            return nil
        }

        return RecordingContextWindowHint(
            processID: frontmostPID,
            title: nil,
            frame: nil
        )
    }

    /// Entry point used by recording context capture. It is intentionally
    /// nonisolated so screenshot acquisition and synchronous Vision OCR can
    /// never execute on MainActor.
    nonisolated static func captureAndExtractText(
        focusedWindowHint: RecordingContextWindowHint,
        currentPID: pid_t
    ) async -> String? {
        await withTimeout(seconds: captureTimeout, operation: {
            await captureAndExtractWindowText(
                focusedWindowHint: focusedWindowHint,
                currentPID: currentPID
            )
        })
    }

    private nonisolated static func captureAndExtractWindowText(
        focusedWindowHint: RecordingContextWindowHint?,
        currentPID: pid_t
    ) async -> String? {
        do {
            // AX calls are synchronous and can traverse another process. They
            // belong here on the generic executor, never in trigger/UI code.
            let focusedWindowHint = enrichFocusedWindowHint(focusedWindowHint)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            guard let window = findActiveWindow(
                in: content.windows,
                focusedWindowHint: focusedWindowHint,
                currentPID: currentPID
            ) else {
                return nil
            }

            let title = window.title ?? window.owningApplication?.applicationName ?? "Unknown"
            let appName = window.owningApplication?.applicationName ?? "Unknown"

            let filter = SCContentFilter(desktopIndependentWindow: window)

            let configuration = SCStreamConfiguration()
            let captureScale = captureScale(for: window.frame.size)
            configuration.width = max(1, Int(window.frame.width * captureScale))
            configuration.height = max(1, Int(window.frame.height * captureScale))

            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)

            var contextText = """
            Active Window: \(title)
            Application: \(appName)

            """

            let extractedText = extractText(from: cgImage)
            if let extractedText, !extractedText.isEmpty {
                contextText += "Window Content:\n\(extractedText)"
            } else {
                contextText += "Window Content:\nNo text detected via OCR"
            }

            return contextText

        } catch {
            return nil
        }
    }

    private nonisolated static func findActiveWindow(
        in windows: [SCWindow],
        focusedWindowHint: RecordingContextWindowHint?,
        currentPID: pid_t
    ) -> SCWindow? {
        let candidates = windows.filter { window in
            guard let processID = window.owningApplication?.processID else {
                return false
            }

            return processID != currentPID &&
                window.windowLayer == 0 &&
                window.isOnScreen &&
                window.frame.width > 0 &&
                window.frame.height > 0
        }

        guard let focusedWindowHint else {
            return candidates.first
        }

        let appWindows = candidates.filter {
            $0.owningApplication?.processID == focusedWindowHint.processID
        }

        guard !appWindows.isEmpty else {
            // Never substitute a different foreground application when the
            // frozen trigger target has already disappeared.
            return nil
        }

        if let focusedFrame = focusedWindowHint.frame,
           let closestWindow = closestFrameMatch(to: focusedFrame, in: appWindows),
           frameDistance(closestWindow.frame, focusedFrame) <= ScreenCaptureGeometry.focusedWindowFrameTolerance {
            return closestWindow
        }

        if let focusedTitle = focusedWindowHint.title,
           let titledWindow = appWindows.first(where: { normalized($0.title) == focusedTitle }) {
            return titledWindow
        }

        return appWindows.first
    }

    private nonisolated static func closestFrameMatch(to frame: CGRect, in windows: [SCWindow]) -> SCWindow? {
        windows.min {
            frameDistance($0.frame, frame) < frameDistance($1.frame, frame)
        }
    }

    private nonisolated static func frameDistance(_ first: CGRect, _ second: CGRect) -> CGFloat {
        abs(first.origin.x - second.origin.x) +
            abs(first.origin.y - second.origin.y) +
            abs(first.size.width - second.size.width) +
            abs(first.size.height - second.size.height)
    }

    private nonisolated static func captureScale(for size: CGSize) -> CGFloat {
        let longestSide = max(size.width, size.height)
        guard longestSide > 0 else {
            return 1
        }

        return min(2, ScreenCaptureGeometry.maximumDimension / longestSide)
    }

    private nonisolated static func extractText(from cgImage: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try requestHandler.perform([request])
            guard let observations = request.results else {
                return nil
            }
            let text = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    private nonisolated static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        try? await NonJoiningTimeout.value(
            nanoseconds: UInt64(max(0, seconds) * 1_000_000_000),
            priority: .utility,
            operation: operation
        )
    }

    private nonisolated static func enrichFocusedWindowHint(
        _ hint: RecordingContextWindowHint?
    ) -> RecordingContextWindowHint? {
        guard let hint, AXIsProcessTrusted() else { return hint }

        let application = AXUIElementCreateApplication(hint.processID)
        guard let focusedWindow = copyAXElementAttribute(
            kAXFocusedWindowAttribute,
            from: application
        ) else {
            return hint
        }

        let title = normalized(copyStringAttribute(kAXTitleAttribute, from: focusedWindow))
        let frame: CGRect?
        if let position = copyCGPointAttribute(kAXPositionAttribute, from: focusedWindow),
           let size = copyCGSizeAttribute(kAXSizeAttribute, from: focusedWindow) {
            frame = CGRect(origin: position, size: size)
        } else {
            frame = hint.frame
        }

        return RecordingContextWindowHint(
            processID: hint.processID,
            title: title ?? hint.title,
            frame: frame
        )
    }

    private nonisolated static func copyAXElementAttribute(
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

    private nonisolated static func copyCGPointAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgPoint else {
            return nil
        }

        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }

        return point
    }

    private nonisolated static func copyCGSizeAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgSize else {
            return nil
        }

        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }

        return size
    }

    private nonisolated static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
