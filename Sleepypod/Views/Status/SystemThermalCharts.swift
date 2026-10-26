import Charts
import SwiftUI

struct SystemThermalCharts: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let data: ThermalChartData
    @State private var position = 1.0
    private var selected: Double { data.from + position * (data.to - data.from) }
    private var celsius: Bool { settings.temperatureFormat == .celsius }
    var body: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Thermal history").font(.headline)
                Text("\(clock(data.from)) → \(clock(data.to))").font(.caption).foregroundStyle(Theme.text2)
                Text("Inspect \(clock(selected))").font(.footnote.monospacedDigit()).accessibilityIdentifier("thermal.inspect.time")
                Slider(value: $position, in: 0...1).accessibilityLabel("Inspect thermal history").accessibilityValue(clock(selected))
                Text("Solid: measured · Dashed: target · Vertical dots: power on. Missing readings leave gaps.").font(.caption).foregroundStyle(Theme.text2)
                ForEach(ThermalPanel.allCases) { panel in panelView(panel) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
    private func clock(_ value: Double) -> String { SystemHealthPath.date(value).formatted(date: .abbreviated, time: .shortened) }
    private func color(_ signal: ThermalSignal) -> Color {
        if signal == .heatsink { return Theme.warm }
        return signal.side == .left ? Theme.text1 : Theme.cool
    }
    private func label(_ signal: ThermalSignal) -> String {
        guard let side = signal.side else { return signal.title }
        let name = settings.sideName(for: side)
        return name == side.displayName ? signal.title : "\(name) · \(signal.title)"
    }
    private func format(_ raw: Double?, panel: ThermalPanel) -> String {
        guard let raw else { return "No reading near this time" }
        let value = celsius && panel != .pump ? (raw - 32) * 5 / 9 : raw
        return panel == .pump ? "\(value.formatted(.number.precision(.fractionLength(0)))) rpm" : "\(value.formatted(.number.precision(.fractionLength(1))))\(celsius ? "°C" : "°F")"
    }
    private func panelView(_ panel: ThermalPanel) -> some View {
        let samples = data.samples(panel, celsius: celsius)
        let nearest = data.nearest(at: selected)
        return VStack(alignment: .leading, spacing: 10) {
            Text(panel.title).font(.subheadline.weight(.semibold))
            if data.available[panel.rawValue] != true || samples.isEmpty {
                Text(panel == .bedTarget && data.bedTargetSince == nil ? "Bed and target history has not started recording." : "No stored readings in this window.").font(.footnote).foregroundStyle(Theme.text2)
            } else {
                Chart {
                    ForEach(samples) { sample in
                        LineMark(x: .value("Time", SystemHealthPath.date(sample.time)), y: .value("Reading", sample.value), series: .value("Segment", "\(sample.signal.rawValue):\(sample.segment)"))
                            .foregroundStyle(by: .value("Signal", sample.signal.rawValue))
                            .lineStyle(.init(lineWidth: 1.5, dash: sample.signal.target ? [4, 4] : []))
                    }
                    ForEach(Array(data.powerOn.enumerated()), id: \.offset) { _, event in
                        if (data.from...data.to).contains(event.at) {
                            RuleMark(x: .value("Power on", SystemHealthPath.date(event.at)))
                                .foregroundStyle(event.side == .left ? Theme.text2 : Theme.cool.opacity(0.6)).lineStyle(.init(lineWidth: 1, dash: [2, 4]))
                        }
                    }
                    RuleMark(x: .value("Selected time", SystemHealthPath.date(selected))).foregroundStyle(Theme.text1.opacity(0.4))
                }.chartXScale(domain: SystemHealthPath.date(data.from)...SystemHealthPath.date(data.to))
                    .chartYScale(domain: domain(samples, panel: panel))
                    .chartForegroundStyleScale(domain: panel.signals.map(\.rawValue), range: panel.signals.map(color))
                    .chartLegend(.hidden).chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine()
                            AxisValueLabel { if let number = value.as(Double.self) { Text(number.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))).font(.caption2).dynamicTypeSize(...DynamicTypeSize.xxxLarge) } }
                        }
                    }
                    .frame(height: dynamicTypeSize.isAccessibilitySize ? 210 : panel == .bedTarget ? 160 : 110)
                    .accessibilityLabel("\(panel.title) history. Use Inspect thermal history for exact readings.")
                ForEach(panel.signals, id: \.self) { signal in
                    Label { Text("\(label(signal)): \(format(nearest?.values[signal], panel: panel))").font(.caption.monospacedDigit()) } icon: {
                        Capsule().fill(color(signal)).frame(width: 16, height: signal.target ? 2 : 4)
                    }
                }
            }
            if panel == .bedTarget, let since = data.bedTargetSince { Text("Recorded since \(clock(since))").font(.caption).foregroundStyle(Theme.text2) }
        }.padding(.vertical, 4).accessibilityIdentifier("thermal.panel.\(panel.rawValue)")
    }
    private func domain(_ samples: [ThermalChartData.Sample], panel: ThermalPanel) -> ClosedRange<Double> {
        guard let low = samples.map(\.value).min(), let high = samples.map(\.value).max() else { return 0...1 }
        if panel == .pump { return 0...max(1000, ceil(high / 1000) * 1000) }
        let padding = max(1, (high - low) * 0.1)
        return (low - padding)...(high + padding)
    }
}
