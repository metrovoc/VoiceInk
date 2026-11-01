import Foundation

extension UserDefaults {
    enum Keys {
        static let audioInputMode = "audioInputMode"
        static let selectedAudioDeviceUID = "selectedAudioDeviceUID"
        static let selectedAudioDeviceModelUID = "selectedAudioDeviceModelUID"
        static let prioritizedDevices = "prioritizedDevices"
        static let audioInputChannelsByDeviceUID = "audioInputChannelsByDeviceUID"
    }

    var audioInputModeRawValue: String? {
        get { string(forKey: Keys.audioInputMode) }
        set { setValue(newValue, forKey: Keys.audioInputMode) }
    }

    var selectedAudioDeviceUID: String? {
        get { string(forKey: Keys.selectedAudioDeviceUID) }
        set { setValue(newValue, forKey: Keys.selectedAudioDeviceUID) }
    }

    var selectedAudioDeviceModelUID: String? {
        get { string(forKey: Keys.selectedAudioDeviceModelUID) }
        set { setValue(newValue, forKey: Keys.selectedAudioDeviceModelUID) }
    }

    var prioritizedDevicesData: Data? {
        get { data(forKey: Keys.prioritizedDevices) }
        set { setValue(newValue, forKey: Keys.prioritizedDevices) }
    }

    var audioInputChannelsByDeviceUID: [String: [UInt32]] {
        get {
            guard let data = data(forKey: Keys.audioInputChannelsByDeviceUID),
                  let selections = try? JSONDecoder().decode([String: [UInt32]].self, from: data) else {
                return [:]
            }
            return selections.filter { $0.value.count == 1 }
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            setValue(data, forKey: Keys.audioInputChannelsByDeviceUID)
        }
    }
}
