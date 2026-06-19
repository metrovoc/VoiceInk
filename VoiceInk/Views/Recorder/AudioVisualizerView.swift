import SwiftUI

struct AudioVisualizerBarModel {
    static let animationInterval: TimeInterval = 1.0 / 30.0

    static func barWeights(count: Int) -> [CGFloat] {
        (0..<count).map { index in
            let center = CGFloat(count - 1) / 2
            let normalizedDistance = abs(CGFloat(index) - center) / max(center, 1)
            let centerBoost = 1.0 - normalizedDistance * 0.42
            let contour = 0.78 + 0.22 * sin(CGFloat(index) * 1.7)
            return max(0.35, centerBoost * contour)
        }
    }

    static func barHeight(
        for index: Int,
        weights: [CGFloat],
        level: Double,
        motionAmount: Double,
        isActive: Bool,
        minHeight: CGFloat,
        maxHeight: CGFloat,
        time: TimeInterval? = nil
    ) -> CGFloat {
        guard isActive else { return minHeight }
        guard weights.indices.contains(index) else { return minHeight }

        let clampedLevel = max(0, min(1, level))
        guard clampedLevel > 0 else { return minHeight }

        let motion = time.map {
            let animated = animatedMotion(for: index, phase: $0 * 8.0)
            return 1.0 + (animated - 1.0) * CGFloat(max(0, min(1, motionAmount)))
        } ?? 1.0
        let heightRatio = min(1, CGFloat(clampedLevel) * weights[index] * motion)

        return minHeight + heightRatio * (maxHeight - minHeight)
    }

    private static func animatedMotion(for index: Int, phase: Double) -> CGFloat {
        let primary = sin(phase + Double(index) * 0.58) * 0.5 + 0.5
        let secondary = sin(phase * 0.47 + Double(index) * 1.13) * 0.5 + 0.5
        return CGFloat(0.58 + primary * 0.34 + secondary * 0.08)
    }
}

struct AudioVisualizerMeterProfile: Equatable {
    let initialNoiseFloorDb: Double
    let minimumNoiseFloorDb: Double
    let maximumNoiseFloorDb: Double
    let speechOnsetMarginDb: Double
    let speechReleaseMarginDb: Double
    let speechFullScaleMarginDb: Double
    let noiseLikeCrestDb: Double
    let peakImpulseCrestDb: Double
    let peakImpulseMarginDb: Double
    let noiseRiseCoefficient: Double
    let noiseFallCoefficient: Double
    let attackCoefficient: Double
    let releaseCoefficient: Double
    let maximumRisePerSample: Double
    let silentFloorLevel: Double
    let speechCandidateReleaseMarginDb: Double
    let coldStartSpeechCandidateMinimumExcessDb: Double
    let coldStartSpeechCandidateMaximumExcessDb: Double
    let coldStartSpeechCandidateMinimumMovementDb: Double
    let coldStartSpeechReleaseMarginDb: Double
    let speechCandidateDuration: TimeInterval
    let noiseCalibrationDuration: TimeInterval
    let referenceFrameInterval: TimeInterval
    let maximumEnvelopeElapsed: TimeInterval

    init(
        initialNoiseFloorDb: Double = -52,
        minimumNoiseFloorDb: Double = -78,
        maximumNoiseFloorDb: Double = -34,
        speechOnsetMarginDb: Double = 7,
        speechReleaseMarginDb: Double = 4,
        speechFullScaleMarginDb: Double = 24,
        noiseLikeCrestDb: Double = 8,
        peakImpulseCrestDb: Double = 12,
        peakImpulseMarginDb: Double = 16,
        noiseRiseCoefficient: Double = 0.65,
        noiseFallCoefficient: Double = 0.05,
        attackCoefficient: Double = 0.30,
        releaseCoefficient: Double = 0.16,
        maximumRisePerSample: Double = 0.14,
        silentFloorLevel: Double = 0.015,
        speechCandidateReleaseMarginDb: Double = 0.75,
        coldStartSpeechCandidateMinimumExcessDb: Double = 1.5,
        coldStartSpeechCandidateMaximumExcessDb: Double = 2.5,
        coldStartSpeechCandidateMinimumMovementDb: Double = 0.75,
        coldStartSpeechReleaseMarginDb: Double = 1,
        speechCandidateDuration: TimeInterval = 0.09,
        noiseCalibrationDuration: TimeInterval = 0.10,
        referenceFrameInterval: TimeInterval = AudioVisualizerBarModel.animationInterval,
        maximumEnvelopeElapsed: TimeInterval = 0.25
    ) {
        self.initialNoiseFloorDb = initialNoiseFloorDb
        self.minimumNoiseFloorDb = minimumNoiseFloorDb
        self.maximumNoiseFloorDb = maximumNoiseFloorDb
        self.speechOnsetMarginDb = speechOnsetMarginDb
        self.speechReleaseMarginDb = speechReleaseMarginDb
        self.speechFullScaleMarginDb = speechFullScaleMarginDb
        self.noiseLikeCrestDb = noiseLikeCrestDb
        self.peakImpulseCrestDb = peakImpulseCrestDb
        self.peakImpulseMarginDb = peakImpulseMarginDb
        self.noiseRiseCoefficient = noiseRiseCoefficient
        self.noiseFallCoefficient = noiseFallCoefficient
        self.attackCoefficient = attackCoefficient
        self.releaseCoefficient = releaseCoefficient
        self.maximumRisePerSample = maximumRisePerSample
        self.silentFloorLevel = silentFloorLevel
        self.speechCandidateReleaseMarginDb = speechCandidateReleaseMarginDb
        self.coldStartSpeechCandidateMinimumExcessDb = coldStartSpeechCandidateMinimumExcessDb
        self.coldStartSpeechCandidateMaximumExcessDb = coldStartSpeechCandidateMaximumExcessDb
        self.coldStartSpeechCandidateMinimumMovementDb = coldStartSpeechCandidateMinimumMovementDb
        self.coldStartSpeechReleaseMarginDb = coldStartSpeechReleaseMarginDb
        self.speechCandidateDuration = speechCandidateDuration
        self.noiseCalibrationDuration = noiseCalibrationDuration
        self.referenceFrameInterval = referenceFrameInterval
        self.maximumEnvelopeElapsed = maximumEnvelopeElapsed
    }
}

struct AudioVisualizerMeterSnapshot: Equatable {
    let level: Double
    let motionAmount: Double
    let isSpeechActive: Bool

    static let silent = AudioVisualizerMeterSnapshot(
        level: 0,
        motionAmount: 0,
        isSpeechActive: false
    )
}

struct AudioVisualizerMeterState: Equatable {
    private(set) var noiseFloorDb: Double
    private(set) var envelope: Double = 0
    private(set) var isSpeechActive = false
    private var speechCandidateElapsed: TimeInterval = 0
    private var speechCandidateMovementDb: Double = 0
    private var lastSpeechCandidateAverageDb: Double?
    private var noiseObservationElapsed: TimeInterval = 0
    private var coldStartSpeechReleaseDb: Double?
    private var lastUpdateTime: TimeInterval?
    private let profile: AudioVisualizerMeterProfile

    init(profile: AudioVisualizerMeterProfile = AudioVisualizerMeterProfile()) {
        self.profile = profile
        self.noiseFloorDb = profile.initialNoiseFloorDb
    }

    mutating func update(
        averageDb: Double,
        peakDb: Double,
        at time: TimeInterval? = nil
    ) -> AudioVisualizerMeterSnapshot {
        let average = clampDb(averageDb)
        let peak = max(average, clampDb(peakDb))
        let crest = peak - average
        let elapsed = elapsedTime(at: time)
        let wasSpeechActive = isSpeechActive

        let onsetDb = noiseFloorDb + profile.speechOnsetMarginDb
        let releaseDb = noiseFloorDb + profile.speechReleaseMarginDb
        let isNoiseFloorCalibrated = noiseObservationElapsed >= profile.noiseCalibrationDuration
        let hasSustainedSpeech: Bool
        if isSpeechActive {
            let uncalibratedReleaseDb = coldStartSpeechReleaseDb ?? releaseDb
            let effectiveReleaseDb = isNoiseFloorCalibrated
                ? releaseDb
                : max(releaseDb, uncalibratedReleaseDb)
            let coldStartSpeechUpperDb = onsetDb + profile.coldStartSpeechCandidateMaximumExcessDb
            hasSustainedSpeech = average > effectiveReleaseDb
                && (isNoiseFloorCalibrated
                    || crest > profile.noiseLikeCrestDb
                    || average <= coldStartSpeechUpperDb)
        } else {
            hasSustainedSpeech = average > onsetDb
                && (isNoiseFloorCalibrated || crest > profile.noiseLikeCrestDb)
        }
        let hasProtectedPeakImpulse = average > releaseDb
            && crest >= profile.peakImpulseCrestDb
            && peak > noiseFloorDb + profile.peakImpulseMarginDb
        let coldStartSpeechCandidateExcess = average - onsetDb
        let isColdStartSpeechCandidate = !isNoiseFloorCalibrated
            && crest <= profile.noiseLikeCrestDb
            && coldStartSpeechCandidateExcess >= profile.coldStartSpeechCandidateMinimumExcessDb
            && coldStartSpeechCandidateExcess <= profile.coldStartSpeechCandidateMaximumExcessDb
        let isSpeechCandidate = !isSpeechActive
            && isNoiseFloorCalibrated
            && average > releaseDb + profile.speechCandidateReleaseMarginDb
            && average <= onsetDb
        let isForegroundCandidate = !isSpeechActive
            && (isSpeechCandidate || isColdStartSpeechCandidate)

        if isForegroundCandidate {
            speechCandidateElapsed += elapsed
            if isColdStartSpeechCandidate {
                if let lastSpeechCandidateAverageDb {
                    speechCandidateMovementDb += abs(average - lastSpeechCandidateAverageDb)
                }
                lastSpeechCandidateAverageDb = average
            } else {
                speechCandidateMovementDb = 0
                lastSpeechCandidateAverageDb = nil
            }
        } else if !isSpeechActive {
            resetSpeechCandidateTracking()
        }

        let hasColdStartCandidateMovement = !isColdStartSpeechCandidate
            || speechCandidateMovementDb >= profile.coldStartSpeechCandidateMinimumMovementDb
        let hasSustainedCandidate = isForegroundCandidate
            && speechCandidateElapsed >= profile.speechCandidateDuration
            && hasColdStartCandidateMovement
        let nextSpeechActive = hasSustainedSpeech
            || hasProtectedPeakImpulse
            || hasSustainedCandidate

        let shouldLearnStableColdStartCandidate = isColdStartSpeechCandidate
            && speechCandidateElapsed >= profile.speechCandidateDuration
            && !hasColdStartCandidateMovement

        if !nextSpeechActive && (!isForegroundCandidate || shouldLearnStableColdStartCandidate) {
            updateNoiseFloor(averageDb: average, crestDb: crest, elapsed: elapsed)
        }
        if nextSpeechActive && !wasSpeechActive && !isNoiseFloorCalibrated {
            let coldStartSpeechReleaseCeilingDb = onsetDb + profile.coldStartSpeechCandidateMinimumExcessDb
            coldStartSpeechReleaseDb = min(
                average - profile.coldStartSpeechReleaseMarginDb,
                coldStartSpeechReleaseCeilingDb
            )
        } else if !nextSpeechActive || isNoiseFloorCalibrated {
            coldStartSpeechReleaseDb = nil
        }
        isSpeechActive = nextSpeechActive
        if isSpeechActive || average <= releaseDb {
            resetSpeechCandidateTracking()
        }

        let targetEnvelope = visualTarget(
            averageDb: average,
            peakDb: peak,
            releaseDb: releaseDb
        )
        updateEnvelope(target: isSpeechActive ? targetEnvelope : 0, elapsed: elapsed)

        let motionAmount = smoothstep((envelope - 0.10) / 0.45)
        return AudioVisualizerMeterSnapshot(
            level: envelope,
            motionAmount: motionAmount,
            isSpeechActive: isSpeechActive
        )
    }

    private mutating func updateNoiseFloor(
        averageDb: Double,
        crestDb: Double,
        elapsed: TimeInterval
    ) {
        guard !isSpeechActive else { return }

        let isNoiseLike = crestDb <= profile.noiseLikeCrestDb
            || averageDb <= noiseFloorDb + profile.speechReleaseMarginDb
        guard isNoiseLike else { return }

        let target = max(
            profile.minimumNoiseFloorDb,
            min(profile.maximumNoiseFloorDb, averageDb - 3)
        )
        let coefficient = target > noiseFloorDb
            ? elapsedAdjustedCoefficient(profile.noiseRiseCoefficient, elapsed: elapsed)
            : elapsedAdjustedCoefficient(profile.noiseFallCoefficient, elapsed: elapsed)
        noiseFloorDb += (target - noiseFloorDb) * coefficient
        noiseObservationElapsed += elapsed
    }

    private mutating func resetSpeechCandidateTracking() {
        speechCandidateElapsed = 0
        speechCandidateMovementDb = 0
        lastSpeechCandidateAverageDb = nil
    }

    private mutating func updateEnvelope(target: Double, elapsed: TimeInterval) {
        let referenceInterval = max(0.001, profile.referenceFrameInterval)
        let stepCount = max(1, elapsed / referenceInterval)
        let perFrameCoefficient = target > envelope
            ? profile.attackCoefficient
            : profile.releaseCoefficient
        let coefficient = 1 - pow(1 - perFrameCoefficient, stepCount)
        var next = envelope + (target - envelope) * coefficient

        if target > envelope {
            let maximumRise = profile.maximumRisePerSample * min(stepCount, 2)
            next = min(next, envelope + maximumRise)
        }
        if target == 0, next < profile.silentFloorLevel {
            next = 0
        }
        envelope = max(0, min(1, next))
    }

    private func elapsedAdjustedCoefficient(_ perFrameCoefficient: Double, elapsed: TimeInterval) -> Double {
        let referenceInterval = max(0.001, profile.referenceFrameInterval)
        let stepCount = max(1, elapsed / referenceInterval)
        return 1 - pow(1 - perFrameCoefficient, stepCount)
    }

    private func visualTarget(averageDb: Double, peakDb: Double, releaseDb: Double) -> Double {
        let speechRange = max(1, profile.speechFullScaleMarginDb - profile.speechReleaseMarginDb)
        let averageLevel = smoothstep((averageDb - releaseDb) / speechRange)
        let peakLevel = smoothstep((peakDb - noiseFloorDb - profile.peakImpulseMarginDb) / 18) * 0.18
        return min(1, pow(max(0, averageLevel + peakLevel), 0.72))
    }

    private func clampDb(_ value: Double) -> Double {
        max(-120, min(0, value.isFinite ? value : -120))
    }

    private mutating func elapsedTime(at time: TimeInterval?) -> TimeInterval {
        guard let time else {
            return profile.referenceFrameInterval
        }

        defer { lastUpdateTime = time }
        guard let lastUpdateTime else {
            return profile.referenceFrameInterval
        }

        let elapsed = time - lastUpdateTime
        guard elapsed.isFinite, elapsed > 0 else {
            return profile.referenceFrameInterval
        }
        return min(elapsed, profile.maximumEnvelopeElapsed)
    }

    private func smoothstep(_ value: Double) -> Double {
        let x = max(0, min(1, value))
        return x * x * (3 - 2 * x)
    }
}

private final class AudioVisualizerMeterStore {
    var state = AudioVisualizerMeterState()

    func reset() {
        state = AudioVisualizerMeterState()
    }
}

struct AudioVisualizer: View {
    let audioMeter: AudioMeter
    let color: Color
    let isActive: Bool

    private let barCount = 15
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2
    private let minHeight: CGFloat = 4
    private let maxHeight: CGFloat = 28

    private let barWeights: [CGFloat]
    @State private var meterStore = AudioVisualizerMeterStore()
    @State private var visualMeter = AudioVisualizerMeterSnapshot.silent

    init(audioMeter: AudioMeter, color: Color, isActive: Bool) {
        self.audioMeter = audioMeter
        self.color = color
        self.isActive = isActive
        self.barWeights = Self.makeBarWeights(count: barCount)
    }

    var body: some View {
        Group {
            if visualMeter.motionAmount > 0.01 {
                TimelineView(.animation(minimumInterval: AudioVisualizerBarModel.animationInterval)) { context in
                    bars(time: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                bars(time: nil)
            }
        }
        .onAppear(perform: updateVisualMeter)
        .onChange(of: audioMeter) {
            updateVisualMeter()
        }
        .onChange(of: isActive) {
            if !isActive {
                meterStore.reset()
                visualMeter = .silent
            }
        }
        .animation(.easeOut(duration: 0.10), value: visualMeter)
    }

    private func bars(time: TimeInterval?) -> some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(color.opacity(0.85))
                    .frame(width: barWidth, height: barHeight(for: index, time: time))
            }
        }
    }

    private func barHeight(for index: Int, time: TimeInterval?) -> CGFloat {
        AudioVisualizerBarModel.barHeight(
            for: index,
            weights: barWeights,
            level: visualMeter.level,
            motionAmount: visualMeter.motionAmount,
            isActive: isActive,
            minHeight: minHeight,
            maxHeight: maxHeight,
            time: time
        )
    }

    private func updateVisualMeter() {
        guard isActive else {
            meterStore.reset()
            visualMeter = .silent
            return
        }
        let nextVisualMeter = meterStore.state.update(
            averageDb: audioMeter.averagePower,
            peakDb: audioMeter.peakPower,
            at: ProcessInfo.processInfo.systemUptime
        )
        if nextVisualMeter != visualMeter {
            visualMeter = nextVisualMeter
        }
    }

    private static func makeBarWeights(count: Int) -> [CGFloat] {
        AudioVisualizerBarModel.barWeights(count: count)
    }
}

// Flat bars shown when the recorder is idle (no audio input)
struct StaticVisualizer: View {
    private let barCount = 15
    private let barWidth: CGFloat = 3
    private let barHeight: CGFloat = 4
    private let barSpacing: CGFloat = 2
    let color: Color

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { _ in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(color.opacity(0.5))
                    .frame(width: barWidth, height: barHeight)
            }
        }
    }
}

// MARK: - Processing Status Display

struct ProcessingStatusDisplay: View {
    enum Mode {
        case starting
        case transcribing
        case enhancing
    }

    let mode: Mode
    let color: Color

    private var label: LocalizedStringKey {
        switch mode {
        case .starting:     return "Starting"
        case .transcribing: return "Transcribing"
        case .enhancing:    return "Enhancing"
        }
    }

    private var animationSpeed: Double {
        switch mode {
        case .starting:     return 0.16
        case .transcribing: return 0.18
        case .enhancing:    return 0.22
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .foregroundColor(color)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            ProgressAnimation(color: color, animationSpeed: animationSpeed)
        }
        .frame(height: 28) // matches AudioVisualizer maxHeight to prevent layout shift
    }
}
