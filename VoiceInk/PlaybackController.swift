import AppKit
import Combine
import Foundation
import SwiftUI
import MediaRemoteAdapter

@MainActor
class PlaybackController: ObservableObject {
    static let shared = PlaybackController()
    private var mediaController: MediaRemoteAdapter.MediaController
    private var activeRecordingSessionID: UUID?
    private var wasPlayingWhenRecordingStarted = false
    private var isMediaPlaying = false
    private var lastKnownTrackInfo: TrackInfo?
    private var originalMediaAppBundleId: String?

    @Published var isPauseMediaEnabled: Bool = UserDefaults.standard.bool(forKey: "isPauseMediaEnabled") {
        didSet {
            UserDefaults.standard.set(isPauseMediaEnabled, forKey: "isPauseMediaEnabled")

            if isPauseMediaEnabled {
                startMediaTracking()
            } else {
                stopMediaTracking()
            }
        }
    }
    
    private init() {
        mediaController = MediaRemoteAdapter.MediaController()

        setupMediaControllerCallbacks()

        if isPauseMediaEnabled {
            startMediaTracking()
        }
    }
    
    private func setupMediaControllerCallbacks() {
        mediaController.onTrackInfoReceived = { [weak self] trackInfo in
            self?.isMediaPlaying = trackInfo?.payload.isPlaying ?? false
            self?.lastKnownTrackInfo = trackInfo
        }
        
        mediaController.onListenerTerminated = { }
    }
    
    private func startMediaTracking() {
        mediaController.startListening()
    }
    
    private func stopMediaTracking() {
        activeRecordingSessionID = nil
        mediaController.stopListening()
        isMediaPlaying = false
        lastKnownTrackInfo = nil
        wasPlayingWhenRecordingStarted = false
        originalMediaAppBundleId = nil
    }

    func beginRecordingSession(_ sessionID: UUID) {
        activeRecordingSessionID = sessionID
    }
    
    func pauseMedia(sessionID: UUID) async {
        guard activeRecordingSessionID == sessionID, !Task.isCancelled else { return }

        if wasPlayingWhenRecordingStarted,
           lastKnownTrackInfo?.payload.bundleIdentifier == originalMediaAppBundleId,
           lastKnownTrackInfo?.payload.isPlaying == false {
            return
        }

        wasPlayingWhenRecordingStarted = false
        originalMediaAppBundleId = nil

        guard isPauseMediaEnabled,
              isMediaPlaying,
              lastKnownTrackInfo?.payload.isPlaying == true,
              let bundleId = lastKnownTrackInfo?.payload.bundleIdentifier else {
            return
        }

        wasPlayingWhenRecordingStarted = true
        originalMediaAppBundleId = bundleId

        try? await Task.sleep(nanoseconds: 50_000_000)
        guard activeRecordingSessionID == sessionID,
              !Task.isCancelled,
              lastKnownTrackInfo?.payload.bundleIdentifier == bundleId,
              lastKnownTrackInfo?.payload.isPlaying == true else {
            wasPlayingWhenRecordingStarted = false
            originalMediaAppBundleId = nil
            return
        }

        mediaController.pause()
    }

    func resumeMedia(sessionID: UUID) async {
        guard activeRecordingSessionID == sessionID, !Task.isCancelled else { return }

        let shouldResume = wasPlayingWhenRecordingStarted
        let originalBundleId = originalMediaAppBundleId
        let delay = MediaController.shared.audioResumptionDelay

        guard isPauseMediaEnabled,
              shouldResume,
              let bundleId = originalBundleId else {
            return
        }

        if delay > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
        }

        guard activeRecordingSessionID == sessionID,
              !Task.isCancelled,
              isAppStillRunning(bundleId: bundleId),
              let currentTrackInfo = lastKnownTrackInfo,
              currentTrackInfo.payload.bundleIdentifier == bundleId,
              currentTrackInfo.payload.isPlaying == false else {
            return
        }

        Self.sendMediaPlayPauseKey()
        wasPlayingWhenRecordingStarted = false
        originalMediaAppBundleId = nil
    }

    /// Simulate the hardware media Play/Pause key (NX_KEYTYPE_PLAY = 16).
    /// Some apps (e.g. Plexamp) ignore the MediaRemote `play` command but
    /// respond to the same HID key event the physical F8 key produces.
    private static func sendMediaPlayPauseKey() {
        func post(down: Bool) {
            let flags: UInt = down ? 0xa00 : 0xb00
            let data1 = Int((16 << 16) | ((down ? 0xa : 0xb) << 8))
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(down: true)
        post(down: false)
    }

    private func isAppStillRunning(bundleId: String) -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps.contains { $0.bundleIdentifier == bundleId }
    }
}
