import Charts
import SwiftUI

struct NightTemperatureChart: View {
    let report: NightExplanation
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dynamicTypeSize) private var typeSize
    private var celsius: Bool { settings.temperatureFormat == .celsius }
    private var actual: [NightTemperatureSeries.Point] { NightTemperatureSeries.points(report.thermal, target: false, celsius: celsius) }
    private var target: [NightTemperatureSeries.Point] { NightTemperatureSeries.points(report.thermal, target: true, celsius: celsius) }
    var body: some View {
        let actual = actual, target = target
        let actualCounts = Dictionary(grouping: actual, by: \.segment).mapValues(\.count)
        let targetCounts = Dictionary(grouping: target, by: \.segment).mapValues(\.count)
        VStack(alignment: .leading, spacing: 12) {
            Text("Pod temperatures").font(.headline)
            Text("Solid blue: reported water temperature. Dashed: Pod-reported target while powered. Gaps over 90 seconds are not joined.").font(.footnote).foregroundStyle(Theme.text2)
            if actual.isEmpty && target.isEmpty { Text("No usable temperature samples in this window.").font(.subheadline) }
            else {
                Chart {
                    ForEach(target) { point in
                        LineMark(x: .value("Time", point.date), y: .value("Target", point.value), series: .value("Recorded segment", "target-\(point.segment)"))
                            .foregroundStyle(Theme.text2).lineStyle(.init(lineWidth: 1.5, dash: [5, 4]))
                        if targetCounts[point.segment] == 1 {
                            PointMark(x: .value("Time", point.date), y: .value("Target", point.value)).foregroundStyle(Theme.text2).symbolSize(10)
                        }
                    }
                    ForEach(actual) { point in
                        LineMark(x: .value("Time", point.date), y: .value("Water", point.value), series: .value("Recorded segment", "reported-\(point.segment)"))
                            .foregroundStyle(Theme.cool).lineStyle(.init(lineWidth: 2))
                        if actualCounts[point.segment] == 1 {
                            PointMark(x: .value("Time", point.date), y: .value("Water", point.value)).foregroundStyle(Theme.cool).symbolSize(10)
                        }
                    }
                }.chartXScale(domain: date(report.start)...date(report.end))
                    .chartYScale(domain: yDomain).chartLegend(.hidden)
                    .chartXAxis {
                        AxisMarks(values: timeTicks) { value in
                            AxisGridLine()
                            AxisValueLabel(anchor: timeAnchor(value.index)) {
                                if let date = value.as(Date.self) { Text(clock(date)).font(.caption2) }
                            }
                        }
                    }
                    .chartYAxis { AxisMarks(position: .leading, values: temperatureTicks) { value in
                        AxisGridLine(); AxisValueLabel {
                            if let value = value.as(Double.self) { Text("\(Int(value.rounded()))°\(celsius ? "C" : "F")").font(.caption2) }
                        }
                    } }
                    .frame(height: typeSize.isAccessibilitySize ? 320 : 170).accessibilityLabel("Recorded Pod temperatures")
                    .accessibilityValue("\(report.thermal.count) retained samples. Target and reported water temperature are separate; recording gaps are not joined.")
                    .accessibilityIdentifier("night.temperatures")
            }
            Text("\(report.thermal.count) retained samples · \(report.side.rawValue) zone · this is not body temperature or measured sleep.").font(.caption).foregroundStyle(Theme.text2)
        }
    }
    private var yDomain: ClosedRange<Double> {
        let values = actual.map(\.value) + target.map(\.value)
        let low = min(celsius ? 18 : 65, values.min() ?? 65), high = max(celsius ? 24 : 75, values.max() ?? 75)
        return floor(low)...ceil(high)
    }
    // Fewer ticks and shorter clock labels keep fully scaled text legible on a phone.
    private var timeTicks: [Date] {
        typeSize.isAccessibilitySize ? [date(report.start), date(report.end)]
            : [date(report.start), date((report.start + report.end) / 2), date(report.end)]
    }
    private var temperatureTicks: [Double] { [yDomain.lowerBound, (yDomain.lowerBound + yDomain.upperBound) / 2, yDomain.upperBound] }
    private func timeAnchor(_ index: Int) -> UnitPoint {
        index == 0 ? .topLeading : index == timeTicks.count - 1 ? .topTrailing : .top
    }
    private func date(_ timestamp: Double) -> Date { Date(timeIntervalSince1970: timestamp / 1000) }
    private func clock(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: report.timeZone)
        formatter.setLocalizedDateFormatFromTemplate(typeSize.isAccessibilitySize ? "j" : "jm")
        return formatter.string(from: date)
    }
}
