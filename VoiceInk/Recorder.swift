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
    /// Lock-protected latest-value handoff read by the recorder UI's display clock.
    /// Meter samples never need to hop through MainActor or invalidate the recorder.
    let audioMeterSource = AudioMeterSource()
    private let audioTaskCoordinator = RecordingAudioTaskCoordinator()
    /// MainActor generation owner used to keep a resumed old stop from
    /// clearing callbacks or restoring media for a newer recording.
    private var activeRecordingContinuity: RecordingAudioContinuity?

    /// Audio chunk callback for streaming. Can be updated while recording;
    /// changes are forwarded to the live CoreAudioRecorder.
    var onAudioChunk: RecordingAudioChunkHandler? {
        didSet { hardwareController.setAudioChunkCallback(onAudioChunk) }
    }
    
    enum RecorderError: Error {
        case couldNotStartRecording
    }
    
    override init() {
        super.init()
        let audioMeterSource = audioMeterSource
        hardwareController.setAudioMeterCallback { meter in
            audioMeterSource.store(meter)
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
            Task { @MainActor in
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
            Task { @MainActor in
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
            Task { @MainActor in
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
            Task { @MainActor in
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
        private let requestStop: @Sendable () -> RecordingHardwareStopHandle

        init(requestStop: @escaping @Sendable () -> RecordingHardwareStopHandle) {
            self.requestStop = requestStop
        }

        @discardableResult
        func requestStopRecording() -> RecordingHardwareStopHandle {
            requestStop()
        }
    }

    func scheduleSystemMute(afterDelayNanoseconds delay: UInt64 = 250_000_000) {
        audioTaskCoordinator.scheduleMute(afterDelayNanoseconds: delay) { [mediaController] in
            _ = await mediaController.muteSystemAudio()
        }
    }

    func beginStartRecording(
        toOutputFile url: URL,
        continuity: RecordingAudioContinuity
    ) -> RecordingHardwareStartHandle {
        #if DEBUG
        let startTime = ProcessInfo.processInfo.systemUptime

        func elapsed() -> Double {
            ProcessInfo.processInfo.systemUptime - startTime
        }
        #endif

        audioTaskCoordinator.cancelRestoration()
        activeRecordingContinuity = continuity
        #if DEBUG
        logger.debug("Recording start preflight completed elapsed=\(elapsed(), format: .fixed(precision: 3), privacy: .public)s")
        #endif

        return hardwareController.beginStartRecording(
            toOutputFile: url,
            continuity: continuity
        )
    }

    func makeHardwareStopper() -> HardwareStopper {
        let hardwareController = hardwareController
        let generationID = activeRecordingContinuity?.sessionID
        return HardwareStopper {
            hardwareController.requestStopRecording(generationID: generationID)
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
        audioTaskCoordinator.schedulePause { [playbackController] in
            await playbackController.pauseMedia()
        }
    }

    func startRecording(toOutputFile url: URL) async throws {
        #if DEBUG
        let startTime = ProcessInfo.processInfo.systemUptime
        #else
        let startTime: TimeInterval? = nil
        #endif

        let continuity = RecordingAudioContinuity(expectsStreaming: false)
        let handle = beginStartRecording(
            toOutputFile: url,
            continuity: continuity
        )
        do {
            let result = try await handle.value()
            finishStartRecording(result, startTime: startTime)
        } catch {
            handle.cancel()
            logger.error("Failed to start recording file=\(url.lastPathComponent, privacy: .public) error=\(error, privacy: .public)")
            await stopRecording(for: continuity)
            throw RecorderError.couldNotStartRecording
        }
    }

    func stopRecording(for expectedContinuity: RecordingAudioContinuity? = nil) async {
        if let expectedContinuity,
           activeRecordingContinuity !== expectedContinuity {
            return
        }
        let stoppingContinuity = expectedContinuity ?? activeRecordingContinuity
        audioTaskCoordinator.cancelStartTasks()

        await hardwareController.stopRecordingHardware(
            generationID: stoppingContinuity?.sessionID
        )

        if let stoppingContinuity {
            guard activeRecordingContinuity === stoppingContinuity else {
                return
            }
        } else {
            guard activeRecordingContinuity == nil else {
                return
            }
        }
        activeRecordingContinuity = nil
        onAudioChunk = nil
        hardwareController.finishStopRecording()

        audioTaskCoordinator.restoreAudio(
            unmute: { [mediaController] in
                await mediaController.unmuteSystemAudio()
            },
            resume: { [playbackController] in
                await playbackController.resumeMedia()
            }
        )
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
        audioTaskCoordinator.cancelAll()
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
    /// Average and peak input power in dBFS as reported by Core Audio.
    let averagePower: Double
    let peakPower: Double
}

enum AudioMeterCadence {
    static let framesPerSecond: Double = 60
    static let interval: TimeInterval = 1.0 / framesPerSecond
    static let intervalNanoseconds = Int(interval * 1_000_000_000)
}

/// A single-slot producer/consumer handoff for metering.
///
/// Core Audio's metering queue is the sole producer and the display timeline is
/// the consumer. Overwriting an unread sample is intentional: rendering an old
/// backlog would add latency without preserving any useful information.
final class AudioMeterSource: @unchecked Sendable {
    static let silence = AudioMeter(averagePower: -160, peakPower: -160)

    private let lock = NSLock()
    private var latestMeter: AudioMeter
    private var sampleSequence: UInt64 = 0

    init(initialValue: AudioMeter = AudioMeterSource.silence) {
        latestMeter = initialValue
    }

    func store(_ meter: AudioMeter) {
        lock.lock()
        latestMeter = meter
        sampleSequence &+= 1
        lock.unlock()
    }

    func snapshot() -> (meter: AudioMeter, sequence: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (latestMeter, sampleSequence)
    }
}
