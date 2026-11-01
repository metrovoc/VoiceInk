import Foundation
import AVFoundation
import CoreAudio
import os

struct AudioInputChannel: Identifiable, Equatable, Sendable {
    let id: UInt32
    let name: String?
}

/// Audio device configuration queries (does NOT modify system default device)
class AudioDeviceConfiguration {
    private static let logger = Logger(subsystem: "com.metrovoc.voiceink", category: "AudioDeviceConfiguration")

    static func inputChannels(deviceID: AudioDeviceID) -> [AudioInputChannel] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else {
            return []
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, storage) == noErr else {
            return []
        }

        let buffers = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self)
        )
        let channelCount = buffers.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
        guard channelCount > 0 else { return [] }

        return (1...channelCount).map { channel in
            AudioInputChannel(
                id: channel,
                name: inputChannelName(deviceID: deviceID, channel: channel)
            )
        }
    }

    private static func inputChannelName(deviceID: AudioDeviceID, channel: UInt32) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyElementName,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: channel
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              let value else {
            return nil
        }
        let name = (value.takeUnretainedValue() as String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Gets the current system default input device (for reference only)
    static func getDefaultInputDevice() -> AudioDeviceID? {
        var defaultDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &defaultDeviceID
        )
        if status != noErr {
            logger.error("Failed to get current default input device: \(status, privacy: .public)")
            return nil
        }
        return defaultDeviceID
    }

    /// Creates a device change observer that calls handler on the specified queue
    static func createDeviceChangeObserver(
        handler: @escaping () -> Void,
        queue: OperationQueue = .main
    ) -> NSObjectProtocol {
        return NotificationCenter.default.addObserver(
            forName: NSNotification.Name("AudioDeviceChanged"),
            object: nil,
            queue: queue,
            using: { _ in handler() }
        )
    }
}
