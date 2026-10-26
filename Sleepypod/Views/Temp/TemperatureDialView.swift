import SwiftUI

struct TemperatureDialView: View {
    @Environment(DeviceManager.self) private var device
    @Environment(UserProfile.self) private var profile
    @Environment(SettingsManager.self) private var settings
    private let size: CGFloat = 300
    /// The source draws r=120 in a 280 viewBox scaled to 300pt.
    private var radius: CGFloat { size * 120 / 280 }
    private var target: Int { device.currentSideStatus?.targetTemperatureF ?? 80 }
    private var bed: Int { device.currentSideStatus?.currentTemperatureF ?? 80 }
    private var color: Color { TempColor.forDelta(target: target, current: bed) }
    private var progress: Double { Double(max(55, min(110, target)) - 55) / 55 }
    private var state: String { !device.isOn ? "OFF" : target < bed ? "COOLING" : target > bed ? "WARMING" : "HOLDING" }
    private var value: String { profile.temperatureDisplay.text(target, unit: settings.temperatureFormat) }
    private var bedFormat: TemperatureFormat {
        settings.temperatureFormat == .relative ? .fahrenheit : settings.temperatureFormat
    }
    private var indicatorOffset: CGSize {
        let angle = (135 + progress * 270) * Double.pi / 180
        return CGSize(width: CGFloat(cos(angle)) * radius, height: CGFloat(sin(angle)) * radius)
    }
    private var bedLabel: String {
        let difference = TemperatureConversion.offsetDisplay(target - bed)
        let measured = TemperatureConversion.displayTemp(bed, format: bedFormat)
        return "\(difference) · bed \(measured)"
    }

    var body: some View {
        ZStack {
            DialArc(radius: radius, progress: 1).stroke(Theme.track, style: StrokeStyle(lineWidth: 6, lineCap: .round))
            DialArc(radius: radius, progress: progress)
                .stroke(device.isOn ? color : Theme.text3, style: StrokeStyle(lineWidth: 6, lineCap: .round))
            Circle().fill(Theme.text1).frame(width: 24, height: 24)
                .offset(indicatorOffset)
            labels
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .animation(.snappy(duration: 0.2), value: target)
        .gesture(DragGesture(minimumDistance: 4).onChanged { drag in updateTarget(at: drag.location) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Target temperature")
        .accessibilityValue("\(value), \(state.lowercased())")
        .accessibilityAdjustableAction { direction in
            guard !device.controlsBlocked(for: device.selectedSide.primarySide) else { return }
            device.setTemperature(profile.temperatureDisplay.step(target, by: direction == .increment ? 1 : -1, unit: settings.temperatureFormat))
        }
    }

    private var labels: some View {
        VStack(spacing: 8) {
            Text(value).font(.mono(76, weight: .light, relativeTo: .largeTitle)).tracking(-2)
                .foregroundStyle(Theme.text1).minimumScaleFactor(0.5).lineLimit(1)
                .contentTransition(.numericText(value: Double(target)))
            Text(bedLabel).font(.mono(13, relativeTo: .footnote)).foregroundStyle(Theme.text2)
            Text(state).font(.caption.weight(.semibold)).tracking(1.2)
                .foregroundStyle(device.isOn ? color : Theme.text3)
        }
        .padding(.horizontal, 40)
        .padding(.top, 8)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    /// Map the touch angle onto the same 270-degree target range as the dial arc.
    private func updateTarget(at location: CGPoint) {
        guard !device.controlsBlocked(for: device.selectedSide.primarySide) else { return }
        let horizontal = Double(location.x - size / 2)
        let vertical = Double(location.y - size / 2)
        var angle = atan2(vertical, horizontal) * 180 / Double.pi
        if angle < 90 { angle += 360 }
        let clamped = min(405, max(135, angle))
        let nextTarget = profile.temperatureDisplay.target(at: (clamped - 135) / 270)
        if nextTarget != target { Haptics.light(); device.setTemperature(nextTarget) }
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
