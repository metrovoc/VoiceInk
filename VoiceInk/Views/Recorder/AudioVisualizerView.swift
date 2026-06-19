import SwiftUI

struct AudioVisualizerBarModel {
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
        averagePower: Double,
        peakPower: Double,
        isActive: Bool,
        minHeight: CGFloat,
        maxHeight: CGFloat
    ) -> CGFloat {
        guard isActive else { return minHeight }
        guard weights.indices.contains(index) else { return minHeight }

        let average = max(0, min(1, averagePower))
        let peak = max(0, min(1, peakPower))
        let amplitude = CGFloat(pow(max(average, peak * 0.72), 0.7))

        return minHeight + amplitude * weights[index] * (maxHeight - minHeight)
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

    init(audioMeter: AudioMeter, color: Color, isActive: Bool) {
        self.audioMeter = audioMeter
        self.color = color
        self.isActive = isActive
        self.barWeights = Self.makeBarWeights(count: barCount)
    }

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(color.opacity(0.85))
                    .frame(width: barWidth, height: barHeight(for: index))
            }
        }
        .animation(.easeOut(duration: 0.08), value: audioMeter.averagePower)
        .animation(.easeOut(duration: 0.08), value: audioMeter.peakPower)
    }

    private func barHeight(for index: Int) -> CGFloat {
        AudioVisualizerBarModel.barHeight(
            for: index,
            weights: barWeights,
            averagePower: audioMeter.averagePower,
            peakPower: audioMeter.peakPower,
            isActive: isActive,
            minHeight: minHeight,
            maxHeight: maxHeight
        )
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
