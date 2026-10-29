import SwiftUI

struct TemperatureDialView: View {
    @Environment(DeviceManager.self) private var device
    @Environment(UserProfile.self) private var profile
    @Environment(SettingsManager.self) private var settings
    private var target: Int { device.currentSideStatus?.targetTemperatureF ?? 80 }
    private var bed: Int { device.currentSideStatus?.currentTemperatureF ?? 80 }
    private var color: Color { TempColor.forDelta(target: target, current: bed) }
    private var progress: Double { Double(max(55, min(110, target)) - 55) / 55 }
    private var state: String { !device.isOn ? "OFF" : target < bed ? "COOLING" : target > bed ? "WARMING" : "HOLDING" }
    private var value: String { profile.temperatureDisplay.text(target, unit: settings.temperatureFormat) }
    private var bedFormat: TemperatureFormat {
        settings.temperatureFormat == .relative ? .fahrenheit : settings.temperatureFormat
    }
    private var bedLabel: String {
        let difference = TemperatureConversion.offsetDisplay(target - bed)
        let measured = TemperatureConversion.displayTemp(bed, format: bedFormat)
        return "\(difference) · bed \(measured)"
    }

    var body: some View {
        TemperatureDialContent(
            valueText: value, detailText: bedLabel, stateText: state, progress: progress,
            tint: device.isOn ? color : Theme.text3, animationValue: Double(target),
            isEnabled: !device.controlsBlocked(for: device.selectedSide.primarySide),
            onProgressChange: { fraction in
                guard !device.controlsBlocked(for: device.selectedSide.primarySide) else { return }
                let nextTarget = profile.temperatureDisplay.target(at: fraction)
                if nextTarget != target { Haptics.light(); device.setTemperature(nextTarget) }
            },
            onAdjustment: { delta in
                guard !device.controlsBlocked(for: device.selectedSide.primarySide) else { return }
                device.setTemperature(profile.temperatureDisplay.step(target, by: delta, unit: settings.temperatureFormat))
            })
    }
}

/// Presentation only: each account supplies its readings and owns every control effect.
struct TemperatureDialContent: View {
    let valueText: String
    let detailText: String
    let stateText: String
    let progress: Double?
    let tint: Color
    let animationValue: Double?
    let isEnabled: Bool
    let onProgressChange: (Double) -> Void
    let onAdjustment: (Int) -> Void
    var onDragEnded: () -> Void = {}
    private var size: CGFloat { 300 }
    /// The source draws r=120 in a 280 viewBox scaled to 300pt.
    private var radius: CGFloat { size * 120 / 280 }
    private var visibleProgress: Double? {
        progress.flatMap { $0.isFinite ? max(0, min(1, $0)) : nil }
    }

    var body: some View {
        ZStack {
            DialArc(radius: radius, progress: 1).stroke(Theme.track, style: StrokeStyle(lineWidth: 6, lineCap: .round))
            if let progress = visibleProgress {
                DialArc(radius: radius, progress: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                Circle().fill(Theme.text1).frame(width: 24, height: 24)
                    .offset(indicatorOffset(progress))
            }
            labels
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .animation(.snappy(duration: 0.2), value: animationValue)
        .gesture(DragGesture(minimumDistance: 4)
            .onChanged { drag in if isEnabled { onProgressChange(fraction(at: drag.location)) } }
            .onEnded { _ in if isEnabled { onDragEnded() } })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Target temperature")
        .accessibilityValue("\(valueText), \(stateText.lowercased())")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            onAdjustment(direction == .increment ? 1 : -1)
        }
    }

    private var labels: some View {
        VStack(spacing: 8) {
            Text(valueText).font(.mono(76, weight: .light, relativeTo: .largeTitle)).tracking(-2)
                .foregroundStyle(Theme.text1).minimumScaleFactor(0.5).lineLimit(1)
                .contentTransition(.numericText(value: animationValue ?? 0))
            Text(detailText).font(.mono(13, relativeTo: .footnote)).foregroundStyle(Theme.text2)
            Text(stateText).font(.caption.weight(.semibold)).tracking(1.2)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 40)
        .padding(.top, 8)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func indicatorOffset(_ progress: Double) -> CGSize {
        let angle = (135 + progress * 270) * Double.pi / 180
        return CGSize(width: CGFloat(cos(angle)) * radius, height: CGFloat(sin(angle)) * radius)
    }

    /// Map a touch onto the same 270-degree arc; the owning workspace converts its display scale.
    private func fraction(at location: CGPoint) -> Double {
        let horizontal = Double(location.x - size / 2)
        let vertical = Double(location.y - size / 2)
        var angle = atan2(vertical, horizontal) * 180 / Double.pi
        if angle < 90 { angle += 360 }
        let clamped = min(405, max(135, angle))
        return (clamped - 135) / 270
    }
}

private struct DialArc: Shape {
    let radius: CGFloat
    let progress: Double
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                        startAngle: .degrees(135), endAngle: .degrees(135 + max(0.001, progress) * 270), clockwise: false)
        }
    }
}
