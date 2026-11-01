import Foundation

struct AudioInputChannelSelection: Equatable, Sendable {
    let deviceChannelIndices: [Int32]

    static func resolve(
        deviceChannelCount: UInt32,
        preferredStereoChannels: [UInt32]?,
        selectedChannels: [UInt32]? = nil
    ) -> AudioInputChannelSelection {
        guard deviceChannelCount > 0 else {
            return AudioInputChannelSelection(deviceChannelIndices: [])
        }

        if let selectedChannels = validatedManualSelection(
            selectedChannels,
            deviceChannelCount: deviceChannelCount
        ) {
            return AudioInputChannelSelection(
                deviceChannelIndices: selectedChannels.map { Int32($0 - 1) }
            )
        }

        let automatic = (0..<min(deviceChannelCount, 2)).map(Int32.init)
        guard let preferredStereoChannels,
              !preferredStereoChannels.isEmpty,
              preferredStereoChannels.allSatisfy({ isValid($0, deviceChannelCount: deviceChannelCount) }) else {
            return AudioInputChannelSelection(deviceChannelIndices: automatic)
        }

        var seen = Set<UInt32>()
        let preferred = preferredStereoChannels.compactMap { channel -> Int32? in
            guard seen.insert(channel).inserted else { return nil }
            return Int32(channel - 1)
        }
        return AudioInputChannelSelection(deviceChannelIndices: preferred)
    }

    static func validatedManualSelection(
        _ channels: [UInt32]?,
        deviceChannelCount: UInt32
    ) -> [UInt32]? {
        guard let channels,
              channels.count == 1,
              channels.allSatisfy({ isValid($0, deviceChannelCount: deviceChannelCount) }) else {
            return nil
        }
        return channels
    }

    private static func isValid(_ channel: UInt32, deviceChannelCount: UInt32) -> Bool {
        channel > 0 && channel <= deviceChannelCount && channel - 1 <= UInt32(Int32.max)
    }
}

enum AudioCaptureRecoveryPolicy {
    static let minimumHealthyDuration: TimeInterval = 0.15

    static func capturedTooLittleAudio(frameCount: Int64, sampleRate: Double) -> Bool {
        guard frameCount >= 0, sampleRate > 0 else { return false }
        return Double(frameCount) / sampleRate < minimumHealthyDuration
    }

    static func preparedFormatMatches(
        preparedSampleRate: Double,
        preparedChannelCount: UInt32,
        currentSampleRate: Double,
        currentChannelCount: UInt32,
        currentFrameCapacity: UInt32,
        allocatedFrameCapacity: UInt32
    ) -> Bool {
        preparedSampleRate == currentSampleRate
            && preparedChannelCount == currentChannelCount
            && currentFrameCapacity <= allocatedFrameCapacity
    }
}
