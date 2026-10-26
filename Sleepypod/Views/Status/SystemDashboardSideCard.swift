import Charts
import SwiftUI

struct SystemDashboardSideCard: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dynamicTypeSize) private var typeSize
    let side: SystemThermalSnapshot.BedSide
    let history: SystemThermalHistory?
    let fresh: Bool
    @State private var position = 1.0
    private var celsius: Bool { settings.temperatureFormat == .celsius }
    private var signal: ThermalSignal {
        let bed: ThermalSignal = side.side == .left ? .leftBed : .rightBed
        return history.map({ history in history.points.contains(where: { $0.timestamp >= history.to - 12 * 3600_000 && $0.values[bed] != nil }) }) == true ? bed : side.side == .left ? .leftSurface : .rightSurface
    }
    private var chart: ThermalChartData? {
        history.map { value in
            let start = max(value.from, value.to - 12 * 3600_000)
            return .init(from: start, to: value.to, gap: value.bucketSec * 3000, points: value.points.filter { $0.timestamp >= start }, powerOn: value.powerOn, available: value.available, bedTargetSince: value.bedTargetSince)
        }
    }
    var body: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(settings.sideName(for: side.side)).font(.headline)
                Text(fresh ? side.direction : "Last reported: \(side.direction)")
                    .font(.subheadline).foregroundStyle(side.verdict == "stalled" ? Theme.red : Theme.text2)
                if let age = side.readingAgeSec {
                    Text("Telemetry age: \(age.formatted(.number.precision(.fractionLength(0...1)))) seconds").font(.caption).foregroundStyle(Theme.text2)
                } else { Text("Telemetry age is unavailable.").font(.caption).foregroundStyle(Theme.text2) }
                if let note = side.note { Text(note).font(.footnote).foregroundStyle(Theme.text2) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: typeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 12) {
                    fact("Bed", temperature(side.currentTempF))
                    fact("Target", side.isPowered ? temperature(side.targetTempF) : "Off")
                    fact("Water", temperature(side.waterTempF))
                    fact("Pump", side.pumpRpm.map { $0.formatted(.number.precision(.fractionLength(0))) + " rpm" } ?? "Unavailable")
                }
                if let chart {
                    let selected = chart.from + position * (chart.to - chart.from)
                    let panel: ThermalPanel = signal == .leftBed || signal == .rightBed ? .bedTarget : .surface
                    let samples = chart.samples(panel, celsius: celsius).filter { $0.signal == signal }
                    Text("Last 12 hours\(panel == .surface ? " · surface sensor" : " · bed temperature")").font(.subheadline)
                    if samples.isEmpty { Text("No measured temperature history.").font(.footnote).foregroundStyle(Theme.text2) }
                    else {
                        Chart {
                            ForEach(samples) { sample in
                                LineMark(x: .value("Time", sample.time), y: .value("Temperature", sample.value), series: .value("Recorded segment", sample.segment))
                                    .foregroundStyle(side.side == .left ? Theme.cool : Theme.purple)
                            }
                            RuleMark(x: .value("Inspect", selected)).foregroundStyle(Theme.text2)
                        }.chartXScale(domain: chart.from...chart.to)
                            .chartYScale(domain: ((samples.map(\.value).min() ?? 0) - 2)...((samples.map(\.value).max() ?? 1) + 2))
                            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                            .chartXAxis(.hidden).frame(height: typeSize.isAccessibilitySize ? 180 : 100)
                            .accessibilityLabel("\(settings.sideName(for: side.side)) temperature during the last twelve hours")
                        Text("\(clock(selected)) · \(temperature(chart.nearest(at: selected)?.values[signal]))").font(.footnote.monospacedDigit())
                        Slider(value: $position, in: 0...1).accessibilityLabel("Inspect \(settings.sideName(for: side.side)) temperature history")
                            .accessibilityIdentifier("dashboard.history.\(side.side.rawValue)")
                    }
                }
                if side.isPowered, let powered = SensorCalibrationProfile.date(side.poweredOnAt) {
                    Text("On since \(clock(powered.timeIntervalSince1970 * 1000))").font(.caption).foregroundStyle(Theme.text2)
                }
                NavigationLink("Thermal details") { SystemThermalScreen() }.accessibilityIdentifier("dashboard.thermal.\(side.side.rawValue)")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(Theme.text2)
            Text(value).font(.subheadline.monospacedDigit()).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func temperature(_ value: Double?) -> String {
        guard let value else { return "—" }
        return (celsius ? (value - 32) * 5 / 9 : value).formatted(.number.precision(.fractionLength(0...1))) + (celsius ? "°C" : "°F")
    }
    private func clock(_ milliseconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: settings.timeZone) ?? .gmt
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: SystemHealthPath.date(milliseconds))
    }
}
