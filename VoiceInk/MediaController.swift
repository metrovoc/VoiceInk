import Foundation
import CoreAudio

@MainActor
final class MediaController: ObservableObject {

    static let shared = MediaController()

    private var activeRecordingSessionID: UUID?
    private var mutedDeviceIDs: Set<AudioDeviceID> = []

    @Published var isSystemMuteEnabled: Bool = UserDefaults.standard.bool(forKey: "isSystemMuteEnabled") {
        didSet { UserDefaults.standard.set(isSystemMuteEnabled, forKey: "isSystemMuteEnabled") }
    }

    @Published var audioResumptionDelay: Double = UserDefaults.standard.double(forKey: "audioResumptionDelay") {
        didSet { UserDefaults.standard.set(audioResumptionDelay, forKey: "audioResumptionDelay") }
    }

    private init() {}

    func beginRecordingSession(_ sessionID: UUID) {
        activeRecordingSessionID = sessionID
    }

    func muteSystemAudio(sessionID: UUID) -> Bool {
        guard activeRecordingSessionID == sessionID,
              !Task.isCancelled,
              isSystemMuteEnabled,
              let deviceID = getDefaultOutputDevice(),
              let isMuted = isSystemAudioMuted(deviceID: deviceID) else {
            return false
        }

        // A device that was already muted belongs to the user, not VoiceInk.
        guard !isMuted else { return true }
        guard setSystemMuted(true, deviceID: deviceID) else { return false }

        mutedDeviceIDs.insert(deviceID)
        return true
    }

    func unmuteSystemAudio(sessionID: UUID) async {
        guard activeRecordingSessionID == sessionID,
              !Task.isCancelled,
              !mutedDeviceIDs.isEmpty else {
            return
        }

        if audioResumptionDelay > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(audioResumptionDelay * 1_000_000_000))
            } catch {
                return
            }
        }

        guard activeRecordingSessionID == sessionID, !Task.isCancelled else { return }

        // Restore every output device VoiceInk muted, including a device that
        // stopped being the default while recording was active.
        for deviceID in Array(mutedDeviceIDs) where setSystemMuted(false, deviceID: deviceID) {
            mutedDeviceIDs.remove(deviceID)
        }
    }

    private func getDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    private func isSystemAudioMuted(deviceID: AudioDeviceID) -> Bool? {
        var muted: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if !AudioObjectHasProperty(deviceID, &address) {
            address.mElement = 0
            if !AudioObjectHasProperty(deviceID, &address) { return nil }
        }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &muted)
        return status == noErr ? muted != 0 : nil
    }

    private func setSystemMuted(_ muted: Bool, deviceID: AudioDeviceID) -> Bool {
        var muteValue: UInt32 = muted ? 1 : 0
        let propertySize = UInt32(MemoryLayout<UInt32>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if !AudioObjectHasProperty(deviceID, &address) {
            address.mElement = 0
            if !AudioObjectHasProperty(deviceID, &address) { return false }
        }

        var isSettable: DarwinBoolean = false
        var status = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        if status != noErr || !isSettable.boolValue { return false }

        status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, propertySize, &muteValue)
        return status == noErr
    }
}
