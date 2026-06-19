import Foundation
import AVFoundation
import CoreAudio
import AppKit
import os

@MainActor
final class Recorder: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "com.metrovoc.voiceink", category: "Recorder")
    private let deviceManager = AudioDeviceManager.shared
    private let hardwareController = RecordingHardwareController()
    private var deviceSwitchObserver: NSObjectProtocol?
    private var audioDeviceChangedObserver: NSObjectProtocol?
    private var isReconfiguring = false
    private let mediaController = MediaController.shared
    private let playbackController = PlaybackController.shared
    private var microphonePermissionObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    @Published var audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
    private var audioMuteTask: Task<Void, Never>?
    private var audioRestorationTask: Task<Void, Never>?

    /// Audio chunk callback for streaming. Can be updated while recording;
    /// changes are forwarded to the live CoreAudioRecorder.
    var onAudioChunk: ((_ data: Data) -> Void)? {
        didSet { hardwareController.setAudioChunkCallback(onAudioChunk) }
    }
    
    enum RecorderError: Error {
        case couldNotStartRecording
    }
    
    override init() {
        super.init()
        hardwareController.setAudioMeterCallback { [weak self] meter in
            DispatchQueue.main.async {
                self?.audioMeter = meter
            }
        }
        setupDeviceSwitchObserver()
        setupAudioDeviceChangedObserver()
        setupMicrophonePermissionObserver()
        setupAppActivationObserver()
        warmUpForCurrentDevice(reason: "init")
    }

    private func setupDeviceSwitchObserver() {
        deviceSwitchObserver = NotificationCenter.default.addObserver(
            forName: .audioDeviceSwitchRequired,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task {
                await self?.handleDeviceSwitchRequired(notification)
            }
        }
    }

    private func setupAudioDeviceChangedObserver() {
        audioDeviceChangedObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("AudioDeviceChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task {
                guard let self, !self.deviceManager.isRecordingActive else { return }
                self.warmUpForCurrentDevice(reason: "device-changed")
            }
        }
    }

    private func setupMicrophonePermissionObserver() {
        microphonePermissionObserver = NotificationCenter.default.addObserver(
            forName: .microphonePermissionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task {
                guard let self, !self.deviceManager.isRecordingActive else { return }
                self.warmUpForCurrentDevice(reason: "microphone-permission-changed")
            }
        }
    }

    private func setupAppActivationObserver() {
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task {
                guard let self, !self.deviceManager.isRecordingActive else { return }
                self.warmUpForCurrentDevice(reason: "app-activated")
            }
        }
    }

    private func handleDeviceSwitchRequired(_ notification: Notification) async {
        guard !isReconfiguring else { return }
        guard let userInfo = notification.userInfo,
              let newDeviceID = userInfo["newDeviceID"] as? AudioDeviceID else {
            logger.error("Device switch notification missing newDeviceID")
            return
        }

        // Prevent concurrent device switches and handleDeviceChange() interference
        isReconfiguring = true
        defer { isReconfiguring = false }

        logger.notice("🎙️ Device switch required: switching to device \(newDeviceID, privacy: .public)")

        do {
            try await hardwareController.switchDevice(to: newDeviceID)

            // Notify user about the switch
            if let deviceName = deviceManager.availableDevices.first(where: { $0.id == newDeviceID })?.name {
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: String(format: String(localized: "Switched to: %@"), deviceName),
                        type: .info
                    )
                }
            }

            logger.notice("🎙️ Successfully switched recording to device \(newDeviceID, privacy: .public)")
        } catch {
            logger.error("❌ Failed to switch device: \(error, privacy: .public)")

            // If switch fails, stop recording and notify user
            await handleRecordingError(error)
        }
    }

    struct HardwareStopper: @unchecked Sendable {
        private let requestStop: @Sendable () -> Void

        init(requestStop: @escaping @Sendable () -> Void) {
            self.requestStop = requestStop
        }

        func requestStopRecording() {
            requestStop()
        }
    }

    func scheduleSystemMute(afterDelayNanoseconds delay: UInt64 = 250_000_000) {
        audioMuteTask?.cancel()
        audioMuteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            _ = await self.mediaController.muteSystemAudio()
        }
    }

    func beginStartRecording(toOutputFile url: URL) -> RecordingHardwareStartHandle {
        #if DEBUG
        let startTime = ProcessInfo.processInfo.systemUptime

        func elapsed() -> Double {
            ProcessInfo.processInfo.systemUptime - startTime
        }
        #endif

        audioRestorationTask?.cancel()
        audioRestorationTask = nil
        #if DEBUG
        logger.debug("Recording start preflight completed elapsed=\(elapsed(), format: .fixed(precision: 3), privacy: .public)s")
        #endif

        return hardwareController.beginStartRecording(toOutputFile: url)
    }

    func makeHardwareStopper() -> HardwareStopper {
        let hardwareController = hardwareController
        return HardwareStopper {
            hardwareController.requestStopRecording()
        }
    }

    func finishStartRecording(_ result: RecordingHardwareStartResult, startTime: TimeInterval? = nil) {
        #if DEBUG
        if let startTime {
            let resumedAt = ProcessInfo.processInfo.systemUptime
            logger.debug("Recording start resumed on main total=\(resumedAt - startTime, format: .fixed(precision: 3), privacy: .public)s")
        }
        #endif
        if result.didChangeFromLastUsedDevice, let deviceName = result.deviceName {
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Using: %@"), deviceName),
                type: .info
            )
        }
        logger.notice("Recording hardware started deviceID=\(result.deviceID, privacy: .public)")
        Task { [weak self] in
            guard let self else { return }
            await self.playbackController.pauseMedia()
        }
    }

    func startRecording(toOutputFile url: URL) async throws {
        #if DEBUG
        let startTime = ProcessInfo.processInfo.systemUptime
        #else
        let startTime: TimeInterval? = nil
        #endif

        let handle = beginStartRecording(toOutputFile: url)
        do {
            let result = try await handle.value()
            finishStartRecording(result, startTime: startTime)
        } catch {
            handle.cancel()
            logger.error("Failed to start recording file=\(url.lastPathComponent, privacy: .public) error=\(error, privacy: .public)")
            await stopRecording()
            throw RecorderError.couldNotStartRecording
        }
    }

    func stopRecording() async {
        audioMuteTask?.cancel()
        audioMuteTask = nil

        await hardwareController.stopRecording()
        onAudioChunk = nil

        audioRestorationTask = Task {
            await mediaController.unmuteSystemAudio()
            await playbackController.resumeMedia()
        }
    }

    private func handleRecordingError(_ error: Error) async {
        logger.error("❌ Recording error occurred: \(error, privacy: .public)")

        // Stop the recording
        await stopRecording()

        // Notify the user about the recording failure
        await MainActor.run {
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Recording Failed: %@"), error.localizedDescription),
                type: .error
            )
        }
    }

    var isPreparedForCurrentDevice: Bool {
        hardwareController.isPreparedForCurrentDevice()
    }

    func warmUpForCurrentDevice(reason: String) {
        hardwareController.warmUpForCurrentDevice(reason: reason)
    }
    
    // MARK: - Cleanup

    deinit {
        audioRestorationTask?.cancel()
        if let observer = deviceSwitchObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = audioDeviceChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = microphonePermissionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = appActivationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        hardwareController.teardown()
    }
}

struct AudioMeter: Equatable {
    let averagePower: Double
    let peakPower: Double
}
