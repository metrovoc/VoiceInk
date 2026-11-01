import CoreAudio
import SwiftUI

struct AudioInputChannelsView: View {
    let deviceID: AudioDeviceID
    @ObservedObject private var deviceManager = AudioDeviceManager.shared

    private var channels: [AudioInputChannel] {
        deviceManager.inputChannelsByDevice[deviceID] ?? []
    }

    private var savedSelection: [UInt32]? {
        deviceManager.selectedInputChannels(for: deviceID)
    }

    private var selectedChannel: UInt32? {
        AudioInputChannelSelection.validatedManualSelection(
            savedSelection,
            deviceChannelCount: UInt32(channels.count)
        )?.first
    }

    private var selection: Binding<UInt32?> {
        Binding(
            get: { selectedChannel },
            set: { deviceManager.setInputChannels($0.map { [$0] }, for: deviceID) }
        )
    }

    var body: some View {
        if channels.count > 1, !deviceManager.isInternalMicrophone(deviceID) {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Input Channel", selection: selection) {
                    Text("Automatic").tag(nil as UInt32?)
                    ForEach(channels) { channel in
                        Text(title(for: channel)).tag(Optional(channel.id))
                    }
                }
                .pickerStyle(.menu)
                .disabled(deviceManager.isRecordingActive)

                if savedSelection != nil, selectedChannel == nil {
                    Text("Saved input is unavailable. VoiceInk CE is using Automatic.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if deviceManager.isRecordingActive {
                    Text("Input channels can be changed after recording stops.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Automatic uses the device's preferred inputs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func title(for channel: AudioInputChannel) -> String {
        if let name = channel.name {
            return String(format: String(localized: "Input %u (%@)"), channel.id, name)
        }
        return String(format: String(localized: "Input %u"), channel.id)
    }
}
