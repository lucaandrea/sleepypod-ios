import SwiftUI
import Charts

struct SensorTrendChart: View, Equatable {
    @Environment(\.dynamicTypeSize) private var typeSize
    let points: [SensorTrendPoint]
    let unit: String
    nonisolated static func == (left: Self, right: Self) -> Bool { left.unit == right.unit && left.points == right.points }
    var body: some View {
        if points.isEmpty { Text("No measurements in this range").font(.footnote).foregroundStyle(Theme.text2).frame(maxWidth: .infinity, minHeight: 100) }
        else {
            Chart(points) { point in
                LineMark(x: .value("Time", point.time), y: .value(unit, point.value), series: .value("Run", point.run))
                    .foregroundStyle(by: .value("Series", point.series))
                if points.count < 3 {
                    PointMark(x: .value("Time", point.time), y: .value(unit, point.value)).foregroundStyle(by: .value("Series", point.series))
                }
            }
            .chartForegroundStyleScale(domain: names, range: names.map { $0 == "Right" ? Theme.warming : $0 == "Ambient" ? Theme.text2 : Theme.cooling })
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: typeSize.isAccessibilitySize ? 2 : 4)) { AxisValueLabel(format: spansDays ? .dateTime.month(.abbreviated).day() : .dateTime.hour().minute()) } }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            .chartYScale(domain: domain)
            .frame(height: typeSize.isAccessibilitySize ? 240 : 180)
            .accessibilityLabel("\(unit) history, \(points.count) measured samples. Gaps remain disconnected.")
        }
    }
    private var spansDays: Bool {
        guard let first = points.map(\.time).min(), let last = points.map(\.time).max() else { return false }
        return last.timeIntervalSince(first) > 86400
    }
    private var names: [String] { ["Left", "Right", "Ambient", "Humidity"].filter { name in points.contains { $0.series == name } } }
    private var domain: ClosedRange<Double> {
        let values = points.map(\.value), lower = values.min() ?? 0, upper = values.max() ?? 1
        let margin = max((upper - lower) * 0.1, 1)
        return (lower - margin)...(upper + margin)
    }
}
