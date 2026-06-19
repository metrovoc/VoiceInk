import Foundation
import AVFoundation
import CoreAudio
import AppKit
import os

@MainActor
class Recorder: NSObject, ObservableObject {
    private var recorder: CoreAudioRecorder?
    private let logger = Logger(subsystem: "com.metrovoc.voiceink", category: "Recorder")
    private let deviceManager = AudioDeviceManager.shared
    private var deviceSwitchObserver: NSObjectProtocol?
    private var audioDeviceChangedObserver: NSObjectProtocol?
    private var isReconfiguring = false
    private let mediaController = MediaController.shared
    private let playbackController = PlaybackController.shared
    private var microphonePermissionObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    @Published var audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
    private var audioMeterUpdateTimer: DispatchSourceTimer?
    private let audioMeterQueue = DispatchQueue(label: "com.metrovoc.voiceink.audiometer", qos: .userInteractive)
    /// Dedicated serial queue for hardware setup.
    private let audioSetupQueue = DispatchQueue(label: "com.metrovoc.voiceink.audioSetup", qos: .userInteractive)
    private var pendingWarmUpWorkItem: DispatchWorkItem?
    private var audioMuteTask: Task<Void, Never>?
    private var audioRestorationTask: Task<Void, Never>?
    private let smoothedValuesLock = NSLock()
    private var smoothedAverage: Float = 0
    private var smoothedPeak: Float = 0
    private let audioMeterPublishLock = NSLock()
    private var lastAudioMeterPublishTime: TimeInterval = 0
    private var lastPublishedAudioAverage: Double = 0
    private var lastPublishedAudioPeak: Double = 0
    private var audioMeterPublishGeneration: UInt64 = 0
    private let audioMeterPublishInterval: TimeInterval = 1.0 / 30.0
    private let audioMeterPublishDelta: Double = 0.015

    /// Audio chunk callback for streaming. Can be updated while recording;
    /// changes are forwarded to the live CoreAudioRecorder.
    var onAudioChunk: ((_ data: Data) -> Void)? {
        didSet { recorder?.onAudioChunk = onAudioChunk }
    }
    
    enum RecorderError: Error {
        case couldNotStartRecording
    }
    
    override init() {
        super.init()
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
        guard let recorder = recorder else { return }
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
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                audioSetupQueue.async {
                    do {
                        try recorder.switchDevice(to: newDeviceID)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

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

    func scheduleSystemMute(afterDelayNanoseconds delay: UInt64 = 250_000_000) {
        audioMuteTask?.cancel()
        audioMuteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            _ = await self.mediaController.muteSystemAudio()
        }
    }

    func startRecording(toOutputFile url: URL) async throws {
        #if DEBUG
        let startTime = ProcessInfo.processInfo.systemUptime

        func elapsed() -> Double {
            ProcessInfo.processInfo.systemUptime - startTime
        }
        #endif

        cancelPendingWarmUp()
        deviceManager.isRecordingActive = true

        let currentDeviceID = deviceManager.getCurrentDevice()
        let lastDeviceID = UserDefaults.standard.string(forKey: "lastUsedMicrophoneDeviceID")
        if String(currentDeviceID) != lastDeviceID {
            if let deviceName = deviceManager.availableDevices.first(where: { $0.id == currentDeviceID })?.name {
                NotificationManager.shared.showNotification(
                    title: String(format: String(localized: "Using: %@"), deviceName),
                    type: .info
                )
            }
        }
        UserDefaults.standard.set(String(currentDeviceID), forKey: "lastUsedMicrophoneDeviceID")

        let deviceID = currentDeviceID

        audioRestorationTask?.cancel()
        audioRestorationTask = nil
        audioMeterUpdateTimer?.cancel()

        let coreAudioRecorder = recorder ?? CoreAudioRecorder()
        coreAudioRecorder.onAudioChunk = onAudioChunk
        recorder = coreAudioRecorder
        #if DEBUG
        logger.debug("Recording start preflight completed deviceID=\(deviceID, privacy: .public) elapsed=\(elapsed(), format: .fixed(precision: 3), privacy: .public)s")
        #endif

        do {
            // Offload hardware start to avoid shortcut lag.
            #if DEBUG
            let logger = logger
            let queueFinishedAt = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double, Error>) in
                let enqueuedAt = ProcessInfo.processInfo.systemUptime
                audioSetupQueue.async {
                    let queueStartedAt = ProcessInfo.processInfo.systemUptime
                    logger.debug("Recording start audio queue began wait=\(queueStartedAt - enqueuedAt, format: .fixed(precision: 3), privacy: .public)s total=\(queueStartedAt - startTime, format: .fixed(precision: 3), privacy: .public)s")
                    do {
                        try coreAudioRecorder.startRecording(toOutputFile: url, deviceID: deviceID)
                        let finishedAt = ProcessInfo.processInfo.systemUptime
                        logger.debug("Recording start audio queue finished duration=\(finishedAt - queueStartedAt, format: .fixed(precision: 3), privacy: .public)s total=\(finishedAt - startTime, format: .fixed(precision: 3), privacy: .public)s")
                        continuation.resume(returning: finishedAt)
                    } catch {
                        let finishedAt = ProcessInfo.processInfo.systemUptime
                        logger.error("Recording start audio queue failed duration=\(finishedAt - queueStartedAt, format: .fixed(precision: 3), privacy: .public)s total=\(finishedAt - startTime, format: .fixed(precision: 3), privacy: .public)s error=\(error, privacy: .public)")
                        continuation.resume(throwing: error)
                    }
                }
            }

            let resumedAt = ProcessInfo.processInfo.systemUptime
            logger.debug("Recording start resumed on main resumeDelay=\(resumedAt - queueFinishedAt, format: .fixed(precision: 3), privacy: .public)s total=\(resumedAt - startTime, format: .fixed(precision: 3), privacy: .public)s")
            #else
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                audioSetupQueue.async {
                    do {
                        try coreAudioRecorder.startRecording(toOutputFile: url, deviceID: deviceID)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            #endif
            startAudioMeterTimer()
            logger.notice("Recording hardware started deviceID=\(deviceID, privacy: .public)")
            Task { [weak self] in
                guard let self else { return }
                await self.playbackController.pauseMedia()
            }
        } catch {
            logger.error("Failed to start recording deviceID=\(deviceID, privacy: .public) file=\(url.lastPathComponent, privacy: .public) error=\(error, privacy: .public)")
            await stopRecording()
            throw RecorderError.couldNotStartRecording
        }
    }

    func stopRecording() async {
        audioMuteTask?.cancel()
        audioMuteTask = nil
        audioMeterUpdateTimer?.cancel()
        audioMeterUpdateTimer = nil

        // Capture current recorder to stop it on the serial hardware queue.
        let currentRecorder = self.recorder
        onAudioChunk = nil

        await withCheckedContinuation { continuation in
            audioSetupQueue.async {
                currentRecorder?.stopRecording()
                continuation.resume()
            }
        }

        smoothedValuesLock.lock()
        smoothedAverage = 0
        smoothedPeak = 0
        smoothedValuesLock.unlock()

        audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
        _ = resetAudioMeterPublishingState()

        audioRestorationTask = Task {
            await mediaController.unmuteSystemAudio()
            await playbackController.resumeMedia()
        }
        deviceManager.isRecordingActive = false
        warmUpForCurrentDevice(reason: "post-stop")
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

    private func startAudioMeterTimer() {
        let generation = resetAudioMeterPublishingState()
        let timer = DispatchSource.makeTimerSource(queue: audioMeterQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            self?.updateAudioMeter(generation: generation)
        }
        timer.resume()
        audioMeterUpdateTimer = timer
    }

    var isPreparedForCurrentDevice: Bool {
        guard let recorder else { return false }
        return recorder.isPreparedForDevice(deviceManager.getCurrentDevice())
    }

    func warmUpForCurrentDevice(reason: String) {
        schedulePrepareForCurrentDevice(reason: reason)
    }

    private func cancelPendingWarmUp() {
        pendingWarmUpWorkItem?.cancel()
        pendingWarmUpWorkItem = nil
    }

    private func schedulePrepareForCurrentDevice(reason: String) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return
        }

        let deviceID = deviceManager.getCurrentDevice()
        guard deviceID != 0 else {
            recorder?.teardown()
            return
        }

        let coreAudioRecorder = recorder ?? CoreAudioRecorder()
        coreAudioRecorder.onAudioChunk = onAudioChunk
        recorder = coreAudioRecorder

        cancelPendingWarmUp()
        let startedAt = ProcessInfo.processInfo.systemUptime
        var workItem: DispatchWorkItem?
        let item = DispatchWorkItem { [logger] in
            guard workItem?.isCancelled == false else { return }
            let wasPrepared = coreAudioRecorder.isPreparedForDevice(deviceID)
            do {
                try coreAudioRecorder.prepare(deviceID: deviceID) {
                    workItem?.isCancelled == true
                }
                logger.notice("Recorder warm-up finished reason=\(reason, privacy: .public) deviceID=\(deviceID, privacy: .public) wasPrepared=\(wasPrepared, privacy: .public) elapsed=\(ProcessInfo.processInfo.systemUptime - startedAt, format: .fixed(precision: 3), privacy: .public)s")
            } catch is CancellationError {
                logger.debug("Recorder warm-up cancelled reason=\(reason, privacy: .public) deviceID=\(deviceID, privacy: .public)")
            } catch {
                logger.warning("Recorder prepare failed reason=\(reason, privacy: .public) deviceID=\(deviceID, privacy: .public) error=\(error, privacy: .public)")
            }
        }
        workItem = item
        pendingWarmUpWorkItem = item
        audioSetupQueue.async(execute: item)
    }

    private func updateAudioMeter(generation: UInt64) {
        guard let recorder = recorder else { return }

        // Sample audio levels (thread-safe read)
        let averagePower = recorder.averagePower
        let peakPower = recorder.peakPower

        // Normalize values
        let minVisibleDb: Float = -60.0
        let maxVisibleDb: Float = 0.0

        let normalizedAverage: Float
        if averagePower < minVisibleDb {
            normalizedAverage = 0.0
        } else if averagePower >= maxVisibleDb {
            normalizedAverage = 1.0
        } else {
            normalizedAverage = (averagePower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        let normalizedPeak: Float
        if peakPower < minVisibleDb {
            normalizedPeak = 0.0
        } else if peakPower >= maxVisibleDb {
            normalizedPeak = 1.0
        } else {
            normalizedPeak = (peakPower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        // Apply EMA smoothing with thread-safe access
        smoothedValuesLock.lock()
        smoothedAverage = smoothedAverage * 0.6 + normalizedAverage * 0.4
        smoothedPeak = smoothedPeak * 0.6 + normalizedPeak * 0.4
        let newAudioMeter = AudioMeter(averagePower: Double(smoothedAverage), peakPower: Double(smoothedPeak))
        smoothedValuesLock.unlock()

        let now = ProcessInfo.processInfo.systemUptime
        audioMeterPublishLock.lock()
        guard generation == audioMeterPublishGeneration else {
            audioMeterPublishLock.unlock()
            return
        }
        let averageDelta = abs(newAudioMeter.averagePower - lastPublishedAudioAverage)
        let peakDelta = abs(newAudioMeter.peakPower - lastPublishedAudioPeak)
        let shouldPublish = now - lastAudioMeterPublishTime >= audioMeterPublishInterval
            && (averageDelta >= audioMeterPublishDelta || peakDelta >= audioMeterPublishDelta)
        if shouldPublish {
            lastAudioMeterPublishTime = now
            lastPublishedAudioAverage = newAudioMeter.averagePower
            lastPublishedAudioPeak = newAudioMeter.peakPower
        }
        audioMeterPublishLock.unlock()

        guard shouldPublish else { return }

        // Dispatch to main queue for UI updates (more efficient than Task)
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  self.isCurrentAudioMeterGeneration(generation) else {
                return
            }
            self.audioMeter = newAudioMeter
        }
    }

    private func resetAudioMeterPublishingState() -> UInt64 {
        audioMeterPublishLock.lock()
        audioMeterPublishGeneration &+= 1
        lastAudioMeterPublishTime = 0
        lastPublishedAudioAverage = 0
        lastPublishedAudioPeak = 0
        let generation = audioMeterPublishGeneration
        audioMeterPublishLock.unlock()
        return generation
    }

    private func isCurrentAudioMeterGeneration(_ generation: UInt64) -> Bool {
        audioMeterPublishLock.lock()
        let isCurrent = generation == audioMeterPublishGeneration
        audioMeterPublishLock.unlock()
        return isCurrent
    }
    
    // MARK: - Cleanup

    deinit {
        audioMeterUpdateTimer?.cancel()
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
        pendingWarmUpWorkItem?.cancel()
        pendingWarmUpWorkItem = nil
        recorder?.teardown()
    }
}

struct AudioMeter: Equatable {
    let averagePower: Double
    let peakPower: Double
}
