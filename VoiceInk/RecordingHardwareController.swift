import AVFoundation
import CoreAudio
import Foundation
import os

struct RecordingHardwareStartResult {
    let deviceID: AudioDeviceID
    let deviceName: String?
    let didChangeFromLastUsedDevice: Bool
}

final class RecordingHardwareStartHandle: @unchecked Sendable {
    private let task: Task<RecordingHardwareStartResult, Error>
    private let cancelClosure: @Sendable () -> Void

    fileprivate init(
        task: Task<RecordingHardwareStartResult, Error>,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.task = task
        self.cancelClosure = cancel
    }

    func value() async throws -> RecordingHardwareStartResult {
        try await task.value
    }

    func cancel() {
        cancelClosure()
        task.cancel()
    }
}

final class RecordingHardwareStartToken: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var _isCancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    func cancel() {
        lock.lock()
        _isCancelled = true
        lock.unlock()
    }
}

final class RecordingHardwareStartCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var activeStartToken: RecordingHardwareStartToken?

    func activate(_ token: RecordingHardwareStartToken) {
        lock.lock()
        activeStartToken?.cancel()
        activeStartToken = token
        lock.unlock()
    }

    func cancelActive() {
        lock.lock()
        activeStartToken?.cancel()
        activeStartToken = nil
        lock.unlock()
    }

    func cancel(_ token: RecordingHardwareStartToken) {
        lock.lock()
        token.cancel()
        if activeStartToken === token {
            activeStartToken = nil
        }
        lock.unlock()
    }

    func clear(_ token: RecordingHardwareStartToken) {
        lock.lock()
        if activeStartToken === token {
            activeStartToken = nil
        }
        lock.unlock()
    }

    func isActive(_ token: RecordingHardwareStartToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeStartToken === token && !token.isCancelled
    }

    func checkActive(_ token: RecordingHardwareStartToken) throws {
        guard isActive(token) else {
            throw CancellationError()
        }
    }
}

final class RecordingHardwareStopHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var isStreamingDrained: Bool
    private var isFinished: Bool
    private var streamingWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    init(isFinished: Bool = false) {
        self.isStreamingDrained = isFinished
        self.isFinished = isFinished
    }

    /// Resolves as soon as AUHAL has stopped and every PCM chunk already
    /// accepted by the streaming handoff has reached its callback. Provider
    /// commit may begin at this point while file draining continues.
    func streamingValue() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isStreamingDrained {
                lock.unlock()
                continuation.resume()
            } else {
                streamingWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func value() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isFinished {
                lock.unlock()
                continuation.resume()
            } else {
                finishWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func finishStreaming() {
        lock.lock()
        guard !isStreamingDrained else {
            lock.unlock()
            return
        }
        isStreamingDrained = true
        let waiters = streamingWaiters
        streamingWaiters.removeAll(keepingCapacity: false)
        lock.unlock()

        for waiter in waiters {
            waiter.resume()
        }
    }

    func finish() {
        // A fully stopped recorder necessarily crossed the streaming barrier.
        // Resolve it first so phase ordering remains deterministic even when a
        // low-level failure skips the normal callback.
        finishStreaming()

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let waiters = finishWaiters
        finishWaiters.removeAll(keepingCapacity: false)
        lock.unlock()

        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// One physical AUHAL drain per recording generation. The first request
/// enqueues synchronously so provider commit can begin in parallel; all later
/// callers receive and await the same completion handle, including callers
/// arriving after the drain has already completed.
final class RecordingHardwareStopCoordinator: @unchecked Sendable {
    private enum Key: Hashable {
        case generation(UUID)
        case unscoped
    }

    private let lock = NSLock()
    private var activeGenerationID: UUID?
    private var handles: [Key: RecordingHardwareStopHandle] = [:]

    func activate(generationID: UUID) {
        lock.lock()
        activeGenerationID = generationID
        handles.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func request(
        generationID: UUID?,
        enqueue: (
            @escaping @Sendable () -> Void,
            @escaping @Sendable () -> Void
        ) -> Void
    ) -> RecordingHardwareStopHandle {
        let key = generationID.map(Key.generation) ?? .unscoped

        lock.lock()
        if let generationID,
           let activeGenerationID,
           generationID != activeGenerationID {
            lock.unlock()
            return RecordingHardwareStopHandle(isFinished: true)
        }
        if let handle = handles[key] {
            lock.unlock()
            return handle
        }
        let handle = RecordingHardwareStopHandle()
        handles[key] = handle
        lock.unlock()

        enqueue(
            { handle.finishStreaming() },
            { handle.finish() }
        )
        return handle
    }
}

final class RecordingHardwareController: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.metrovoc.voiceink", category: "RecordingHardwareController")
    private let deviceResolver = RecordingInputDeviceResolver()
    private let deviceManager = AudioDeviceManager.shared

    private let audioSetupQueue = DispatchQueue(label: "com.metrovoc.voiceink.audioSetup", qos: .userInteractive)
    private let audioMeterQueue = DispatchQueue(label: "com.metrovoc.voiceink.audiometer", qos: .userInteractive)

    private let recorderLock = NSLock()
    private var recorder: CoreAudioRecorder?

    private let callbackLock = NSLock()
    private var audioChunkCallback: RecordingAudioChunkHandler?
    private var audioMeterCallback: (@Sendable (AudioMeter) -> Void)?

    private let warmUpLock = NSLock()
    private var pendingWarmUpWorkItem: DispatchWorkItem?

    private let startCoordinator = RecordingHardwareStartCoordinator()
    private let stopCoordinator = RecordingHardwareStopCoordinator()

    private let audioMeterGenerationLock = NSLock()
    private let audioMeterTimerLock = NSLock()
    private var audioMeterUpdateTimer: DispatchSourceTimer?
    private var audioMeterStopRequestGeneration: UInt64 = 0
    private var audioMeterGeneration: UInt64 = 0

    deinit {
        stopAudioMeterTimer()
        cancelPendingWarmUp()
        audioSetupQueue.sync {
            recorder?.teardown()
            recorder = nil
        }
    }

    func setAudioChunkCallback(_ callback: RecordingAudioChunkHandler?) {
        callbackLock.lock()
        audioChunkCallback = callback
        callbackLock.unlock()

        audioSetupQueue.async { [weak self] in
            self?.recorder?.onAudioChunk = callback
        }
    }

    func setAudioMeterCallback(_ callback: (@Sendable (AudioMeter) -> Void)?) {
        callbackLock.lock()
        audioMeterCallback = callback
        callbackLock.unlock()
    }

    func beginStartRecording(
        toOutputFile url: URL,
        continuity: RecordingAudioContinuity
    ) -> RecordingHardwareStartHandle {
        stopCoordinator.activate(generationID: continuity.sessionID)
        let token = RecordingHardwareStartToken()
        startCoordinator.activate(token)
        let task = Task(priority: .userInitiated) { [weak self, token] in
            guard let self else { throw CancellationError() }
            return try await self.startRecording(
                toOutputFile: url,
                continuity: continuity,
                token: token
            )
        }
        return RecordingHardwareStartHandle(task: task) { [weak self, token] in
            token.cancel()
            self?.startCoordinator.cancel(token)
        }
    }

    func startRecording(
        toOutputFile url: URL,
        continuity: RecordingAudioContinuity
    ) async throws -> RecordingHardwareStartResult {
        try await beginStartRecording(
            toOutputFile: url,
            continuity: continuity
        ).value()
    }

    private func startRecording(
        toOutputFile url: URL,
        continuity: RecordingAudioContinuity,
        token: RecordingHardwareStartToken
    ) async throws -> RecordingHardwareStartResult {
        #if DEBUG
        let startTime = ProcessInfo.processInfo.systemUptime
        #endif

        cancelPendingWarmUp()
        deviceManager.isRecordingActive = true
        stopAudioMeterTimer()
        let stopRequestGeneration = currentAudioMeterStopRequestGeneration()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                #if DEBUG
                let enqueuedAt = ProcessInfo.processInfo.systemUptime
                #endif
                audioSetupQueue.async { [weak self, token] in
                    guard let self else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    #if DEBUG
                    let queueStartedAt = ProcessInfo.processInfo.systemUptime
                    self.logger.debug("Recording hardware queue began wait=\(queueStartedAt - enqueuedAt, format: .fixed(precision: 3), privacy: .public)s total=\(queueStartedAt - startTime, format: .fixed(precision: 3), privacy: .public)s")
                    #endif

                    do {
                        try self.startCoordinator.checkActive(token)

                        let device = self.deviceResolver.resolveCurrentInputDevice()
                        try self.startCoordinator.checkActive(token)

                        let lastDeviceID = UserDefaults.standard.string(forKey: "lastUsedMicrophoneDeviceID")
                        let didChangeFromLastUsedDevice = String(device.id) != lastDeviceID
                        UserDefaults.standard.set(String(device.id), forKey: "lastUsedMicrophoneDeviceID")

                        let coreAudioRecorder = self.recorderOnQueue()
                        coreAudioRecorder.onAudioChunk = self.currentAudioChunkCallback()
                        try coreAudioRecorder.startRecording(
                            toOutputFile: url,
                            deviceID: device.id,
                            continuity: continuity
                        ) {
                            !self.startCoordinator.isActive(token)
                        }
                        try self.startCoordinator.checkActive(token)

                        try self.startCoordinator.checkActive(token)
                        _ = self.startAudioMeterTimer(
                            ifStopRequestGenerationMatches: stopRequestGeneration
                        )
                        self.startCoordinator.clear(token)
                        let result = RecordingHardwareStartResult(
                            deviceID: device.id,
                            deviceName: device.name,
                            didChangeFromLastUsedDevice: didChangeFromLastUsedDevice
                        )

                        #if DEBUG
                        let finishedAt = ProcessInfo.processInfo.systemUptime
                        self.logger.debug("Recording hardware queue finished duration=\(finishedAt - queueStartedAt, format: .fixed(precision: 3), privacy: .public)s total=\(finishedAt - startTime, format: .fixed(precision: 3), privacy: .public)s")
                        #endif
                        continuation.resume(returning: result)
                    } catch {
                        if self.startCoordinator.isActive(token) {
                            self.deviceManager.isRecordingActive = false
                            self.stopAudioMeterTimer()
                            self.startCoordinator.clear(token)
                        }
                        #if DEBUG
                        let finishedAt = ProcessInfo.processInfo.systemUptime
                        self.logger.error("Recording hardware queue failed duration=\(finishedAt - queueStartedAt, format: .fixed(precision: 3), privacy: .public)s total=\(finishedAt - startTime, format: .fixed(precision: 3), privacy: .public)s error=\(error, privacy: .public)")
                        #endif
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            token.cancel()
            self.startCoordinator.cancel(token)
        }
    }

    func stopRecording(generationID: UUID? = nil) async {
        await stopRecordingHardware(generationID: generationID)
        finishStopRecording()
    }

    /// Drains/stops AUHAL without publishing presentation state or scheduling
    /// post-stop warm-up. `Recorder` uses this split operation so it can
    /// revalidate generation ownership after the suspension point first.
    func stopRecordingHardware(generationID: UUID? = nil) async {
        let handle = requestStopRecording(generationID: generationID)
        await handle.value()
    }

    func finishStopRecording() {
        publishAudioMeter(AudioMeter(averagePower: -160, peakPower: -160))
        warmUpForCurrentDevice(reason: "post-stop")
    }

    @discardableResult
    func requestStopRecording(generationID: UUID? = nil) -> RecordingHardwareStopHandle {
        stopCoordinator.request(generationID: generationID) { [weak self] streamingDrained, completion in
            guard let self else {
                streamingDrained()
                completion()
                return
            }
            self.enqueueStopRecording(
                onStreamingDrained: streamingDrained,
                onStopped: completion
            )
        }
    }

    func warmUpForCurrentDevice(reason: String) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return
        }

        cancelPendingWarmUp()
        let startedAt = ProcessInfo.processInfo.systemUptime
        var workItem: DispatchWorkItem?
        let item = DispatchWorkItem { [weak self] in
            guard let self, workItem?.isCancelled == false else { return }
            let device = self.deviceResolver.resolveCurrentInputDevice()
            guard device.id != 0 else {
                self.teardownRecorderOnQueue()
                return
            }

            let coreAudioRecorder = self.recorderOnQueue()
            coreAudioRecorder.onAudioChunk = self.currentAudioChunkCallback()
            let wasPrepared = coreAudioRecorder.isPreparedForDevice(device.id)
            do {
                try coreAudioRecorder.prepare(deviceID: device.id) {
                    workItem?.isCancelled == true
                }
                self.logger.notice("Recorder warm-up finished reason=\(reason, privacy: .public) deviceID=\(device.id, privacy: .public) wasPrepared=\(wasPrepared, privacy: .public) elapsed=\(ProcessInfo.processInfo.systemUptime - startedAt, format: .fixed(precision: 3), privacy: .public)s")
            } catch is CancellationError {
                self.logger.debug("Recorder warm-up cancelled reason=\(reason, privacy: .public) deviceID=\(device.id, privacy: .public)")
            } catch {
                self.logger.warning("Recorder prepare failed reason=\(reason, privacy: .public) deviceID=\(device.id, privacy: .public) error=\(error, privacy: .public)")
            }
        }
        workItem = item

        warmUpLock.lock()
        pendingWarmUpWorkItem = item
        warmUpLock.unlock()

        audioSetupQueue.async(execute: item)
    }

    func isPreparedForCurrentDevice() -> Bool {
        let device = deviceResolver.resolveCurrentInputDevice()
        guard device.id != 0, let recorder = recorderSnapshot() else { return false }
        return recorder.isPreparedForDevice(device.id)
    }

    func switchDevice(to newDeviceID: AudioDeviceID) async throws {
        guard let currentRecorder = recorderSnapshot() else { return }
        try await withCheckedThrowingContinuation { continuation in
            audioSetupQueue.async {
                do {
                    try currentRecorder.switchDevice(to: newDeviceID)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func teardown() {
        stopAudioMeterTimer()
        cancelPendingWarmUp()
        audioSetupQueue.async { [weak self] in
            self?.teardownRecorderOnQueue()
        }
    }

    private func enqueueStopRecording(
        onStreamingDrained: (@Sendable () -> Void)? = nil,
        onStopped: (@Sendable () -> Void)? = nil
    ) {
        startCoordinator.cancelActive()
        cancelPendingWarmUp()
        stopAudioMeterTimer(markStopRequest: true)

        audioSetupQueue.async { [weak self] in
            guard let self else {
                onStreamingDrained?()
                onStopped?()
                return
            }
            if let recorder = self.recorderSnapshot() {
                recorder.stopRecording(onStreamingDrained: onStreamingDrained)
            } else {
                onStreamingDrained?()
            }
            self.stopAudioMeterTimer()
            self.deviceManager.isRecordingActive = false
            onStopped?()
        }
    }

    private func cancelPendingWarmUp() {
        warmUpLock.lock()
        pendingWarmUpWorkItem?.cancel()
        pendingWarmUpWorkItem = nil
        warmUpLock.unlock()
    }

    private func currentAudioChunkCallback() -> RecordingAudioChunkHandler? {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        return audioChunkCallback
    }

    private func currentAudioMeterCallback() -> (@Sendable (AudioMeter) -> Void)? {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        return audioMeterCallback
    }

    private func recorderSnapshot() -> CoreAudioRecorder? {
        recorderLock.lock()
        defer { recorderLock.unlock() }
        return recorder
    }

    private func recorderOnQueue() -> CoreAudioRecorder {
        recorderLock.lock()
        defer { recorderLock.unlock() }
        if let recorder {
            return recorder
        }
        let recorder = CoreAudioRecorder()
        self.recorder = recorder
        return recorder
    }

    private func teardownRecorderOnQueue() {
        recorderLock.lock()
        let recorder = self.recorder
        self.recorder = nil
        recorderLock.unlock()
        recorder?.teardown()
    }

    private func startAudioMeterTimer(ifStopRequestGenerationMatches expectedGeneration: UInt64) -> Bool {
        audioMeterTimerLock.lock()
        guard audioMeterStopRequestGeneration == expectedGeneration else {
            audioMeterTimerLock.unlock()
            return false
        }

        let generation = advanceAudioMeterGeneration()
        let timer = DispatchSource.makeTimerSource(queue: audioMeterQueue)
        timer.schedule(
            deadline: .now(),
            repeating: .nanoseconds(AudioMeterCadence.intervalNanoseconds),
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.updateAudioMeter(generation: generation)
        }
        audioMeterUpdateTimer?.cancel()
        audioMeterUpdateTimer = timer
        timer.resume()
        audioMeterTimerLock.unlock()
        return true
    }

    private func stopAudioMeterTimer(markStopRequest: Bool = false) {
        audioMeterTimerLock.lock()
        if markStopRequest {
            audioMeterStopRequestGeneration &+= 1
        }
        let timer = audioMeterUpdateTimer
        audioMeterUpdateTimer = nil
        audioMeterTimerLock.unlock()

        timer?.cancel()
        _ = advanceAudioMeterGeneration()
    }

    private func currentAudioMeterStopRequestGeneration() -> UInt64 {
        audioMeterTimerLock.lock()
        let generation = audioMeterStopRequestGeneration
        audioMeterTimerLock.unlock()
        return generation
    }

    private func updateAudioMeter(generation: UInt64) {
        guard let recorder = recorderSnapshot() else { return }

        let newAudioMeter = AudioMeter(
            averagePower: Double(recorder.averagePower),
            peakPower: Double(recorder.peakPower)
        )
        audioMeterGenerationLock.lock()
        let isCurrentGeneration = generation == audioMeterGeneration
        audioMeterGenerationLock.unlock()

        guard isCurrentGeneration else { return }
        publishAudioMeter(newAudioMeter)
    }

    private func advanceAudioMeterGeneration() -> UInt64 {
        audioMeterGenerationLock.lock()
        audioMeterGeneration &+= 1
        let generation = audioMeterGeneration
        audioMeterGenerationLock.unlock()
        return generation
    }

    private func publishAudioMeter(_ audioMeter: AudioMeter) {
        currentAudioMeterCallback()?(audioMeter)
    }
}

private struct RecordingInputDevice {
    let id: AudioDeviceID
    let uid: String?
    let name: String?
    let modelUID: String?
}

private struct RecordingInputDeviceResolver {
    private let logger = Logger(subsystem: "com.metrovoc.voiceink", category: "RecordingInputDeviceResolver")

    func resolveCurrentInputDevice() -> RecordingInputDevice {
        let devices = availableInputDevices()
        let defaults = UserDefaults.standard
        let rawMode = defaults.audioInputModeRawValue ?? AudioInputMode.systemDefault.rawValue
        let mode = AudioInputMode(rawValue: rawMode) ?? .systemDefault

        switch mode {
        case .systemDefault:
            if let defaultID = systemDefaultInputDevice(),
               let device = device(for: defaultID, in: devices) {
                return device
            }
        case .custom:
            let savedUID = defaults.selectedAudioDeviceUID ?? ""
            let savedModelUID = defaults.selectedAudioDeviceModelUID
            if let device = findDevice(uid: savedUID, modelUID: savedModelUID, in: devices) {
                return device
            }
        case .prioritized:
            if let data = defaults.prioritizedDevicesData,
               let prioritizedDevices = try? JSONDecoder().decode([PrioritizedDevice].self, from: data) {
                let sortedDevices = prioritizedDevices.sorted { $0.priority < $1.priority }
                for saved in sortedDevices {
                    if let device = findDevice(uid: saved.id, modelUID: saved.modelUID, in: devices) {
                        return device
                    }
                }
            }
        }

        return bestFallbackDevice(in: devices) ?? RecordingInputDevice(id: 0, uid: nil, name: nil, modelUID: nil)
    }

    private func availableInputDevices() -> [RecordingInputDevice] {
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize
        )

        guard status == noErr else {
            logger.error("Error getting audio device list size: \(status, privacy: .public)")
            return []
        }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        guard deviceCount > 0 else { return [] }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceIDs
        )

        guard status == noErr else {
            logger.error("Error getting audio devices: \(status, privacy: .public)")
            return []
        }

        return deviceIDs.compactMap { deviceID in
            guard isValidInputDevice(deviceID: deviceID) else { return nil }
            return RecordingInputDevice(
                id: deviceID,
                uid: getDeviceStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID),
                name: getDeviceStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceNameCFString),
                modelUID: getDeviceStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyModelUID)
            )
        }
    }

    private func systemDefaultInputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
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
            &deviceID
        )

        guard status == noErr, deviceID != 0 else {
            logger.error("Failed to get system default input device: \(status, privacy: .public)")
            return nil
        }
        return deviceID
    }

    private func bestFallbackDevice(in devices: [RecordingInputDevice]) -> RecordingInputDevice? {
        devices.first { device in
            guard let uid = device.uid else { return false }
            return uid.contains("BuiltIn")
        } ?? devices.first
    }

    private func device(for id: AudioDeviceID, in devices: [RecordingInputDevice]) -> RecordingInputDevice? {
        devices.first { $0.id == id }
    }

    private func findDevice(
        uid: String,
        modelUID: String?,
        in devices: [RecordingInputDevice]
    ) -> RecordingInputDevice? {
        if !uid.isEmpty, let device = devices.first(where: { $0.uid == uid }) {
            return device
        }
        if let modelUID, !modelUID.isEmpty,
           let device = devices.first(where: { $0.modelUID == modelUID }) {
            return device
        }
        return nil
    }

    private func isValidInputDevice(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &propertySize
        )

        guard status == noErr, propertySize > 0 else {
            return false
        }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(propertySize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBuffer.deallocate() }

        status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            rawBuffer
        )

        guard status == noErr else { return false }
        let bufferList = rawBuffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        return bufferList.pointee.mNumberBuffers > 0
    }

    private func getDeviceStringProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var property: Unmanaged<CFString>?

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &property
        )

        guard status == noErr, let property else { return nil }
        return property.takeUnretainedValue() as String
    }
}
