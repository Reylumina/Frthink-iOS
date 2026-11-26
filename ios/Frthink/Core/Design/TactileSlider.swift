import SwiftUI

/// 带轨道扩张动效、离散刻度点与步进触感反馈的编辑滑块。
///
/// 系统原生 `Slider` 缺少按下时轨道弹性扩张、离散档位刻度视觉反馈与按步进触发的触感节拍；
/// 本组件仅补充上述交互能力，视觉完全取自 `Theme` 语义色、无投影连续形状与 `Theme.motionSelection`。
struct TactileSlider: View {
    @Binding var value: Double
    private let range: ClosedRange<Double>
    private let step: Double?
    private let showTicks: Bool
    private let hapticsEnabled: Bool
    private let onEditingChanged: ((Bool) -> Void)?

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double? = nil,
        showTicks: Bool = true,
        hapticsEnabled: Bool = true,
        onEditingChanged: ((Bool) -> Void)? = nil
    ) {
        self._value = value
        self.range = range
        self.step = step
        self.showTicks = showTicks
        self.hapticsEnabled = hapticsEnabled
        self.onEditingChanged = onEditingChanged
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var isDragging = false
    @State private var wasDragging = false

    @ScaledMetric(relativeTo: .body) private var thumbRestDiameter: CGFloat = 18
    @ScaledMetric(relativeTo: .body) private var thumbActiveDiameter: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var trackRestHeight: CGFloat = 6
    @ScaledMetric(relativeTo: .body) private var trackActiveHeight: CGFloat = 10
    @ScaledMetric(relativeTo: .body) private var sliderHeight: CGFloat = 32

    private var span: Double {
        max(0.0001, range.upperBound - range.lowerBound)
    }

    private var clampedValue: Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private var progress: Double {
        (clampedValue - range.lowerBound) / span
    }

    private var discreteStepCount: Int? {
        guard let step, step > 0 else { return nil }
        let intervals = Int((span / step).rounded())
        guard intervals >= 1, intervals <= 16 else { return nil }
        return intervals + 1
    }

    private var currentStepIndex: Int {
        guard let step, step > 0 else {
            return Int((progress * 20).rounded())
        }
        return Int(((clampedValue - range.lowerBound) / step).rounded())
    }

    var body: some View {
        GeometryReader { proxy in
            let horizontalInset = thumbActiveDiameter / 2
            let trackWidth = max(1, proxy.size.width - horizontalInset * 2)
            let activeTrackHeight = isDragging ? trackActiveHeight : trackRestHeight
            let thumbDiameter = isDragging ? thumbActiveDiameter : thumbRestDiameter
            let thumbCenterX = horizontalInset + trackWidth * progress
            let fillWidth = max(activeTrackHeight, trackWidth * progress + activeTrackHeight / 2)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.field)
                    .frame(width: trackWidth, height: activeTrackHeight)
                    .offset(x: horizontalInset)

                Capsule()
                    .fill(Theme.accent)
                    .frame(width: min(trackWidth, fillWidth), height: activeTrackHeight)
                    .offset(x: horizontalInset)

                if showTicks, let tickCount = discreteStepCount, tickCount > 1 {
                    let dotDiameter: CGFloat = 3
                    ForEach(0..<tickCount, id: \.self) { idx in
                        let ratio = Double(idx) / Double(tickCount - 1)
                        let dotX = horizontalInset + trackWidth * ratio - dotDiameter / 2
                        let filled = ratio <= progress + 0.0001
                        Circle()
                            .fill(filled ? Theme.onAccent : Theme.separator)
                            .frame(width: dotDiameter, height: dotDiameter)
                            .offset(x: dotX)
                    }
                }

                Circle()
                    .fill(Theme.pageBackgroundColor)
                    .overlay {
                        Circle()
                            .strokeBorder(Theme.accent, lineWidth: isDragging ? 3 : 2.5)
                    }
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .offset(x: thumbCenterX - thumbDiameter / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, state, _ in
                        state = true
                    }
                    .onChanged { gesture in
                        let rawFraction = (gesture.location.x - horizontalInset) / trackWidth
                        let bounded = min(max(rawFraction, 0), 1)
                        let rawValue = range.lowerBound + bounded * span
                        let nextValue = snappedValue(rawValue)
                        if abs(nextValue - value) > 0.000001 {
                            value = nextValue
                        }
                    }
            )
        }
        .frame(height: sliderHeight)
        .animation(Theme.motion(Theme.motionSelection, reduceMotion: reduceMotion), value: isDragging)
        .animation(Theme.motion(Theme.motionSelection, reduceMotion: reduceMotion), value: clampedValue)
        .sensoryFeedback(.selection, trigger: currentStepIndex) { _, _ in
            hapticsEnabled && isDragging
        }
        .onChange(of: isDragging) { _, nowDragging in
            guard nowDragging != wasDragging else { return }
            wasDragging = nowDragging
            onEditingChanged?(nowDragging)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue(accessibleValueText)
        .accessibilityAdjustableAction { direction in
            let delta = step ?? max(span / 10, 0.05)
            switch direction {
            case .increment:
                let next = snappedValue(value + delta)
                if next != value {
                    value = next
                    onEditingChanged?(false)
                }
            case .decrement:
                let next = snappedValue(value - delta)
                if next != value {
                    value = next
                    onEditingChanged?(false)
                }
            @unknown default:
                break
            }
        }
    }

    private var accessibleValueText: String {
        if let step, step >= 1 {
            return "\(Int(clampedValue.rounded()))"
        }
        return String(format: "%.2f", clampedValue)
    }

    private func snappedValue(_ raw: Double) -> Double {
        let clamped = min(max(raw, range.lowerBound), range.upperBound)
        guard let step, step > 0 else { return clamped }
        let steps = ((clamped - range.lowerBound) / step).rounded()
        let snapped = range.lowerBound + steps * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}
