import SwiftUI
import Charts

struct AnalysisMeasurementsCard: View {
    let records: [ImportedVitalsRecord]
    let sideName: String
    let timeZone: String
    @State private var metric = Metric.heartRate
    @ScaledMetric(relativeTo: .caption) private var chartHeight: CGFloat = 150
    private enum Metric: String, CaseIterable {
        case heartRate = "Heart rate", hrv = "HRV", breathing = "Breathing"
        var unit: String {
            switch self {
            case .heartRate: "bpm"
            case .hrv: "ms"
            case .breathing: "breaths/min"
            }
        }
        func value(_ record: ImportedVitalsRecord) -> Double? {
            let value: Double? = switch self {
            case .heartRate: record.heartRateBpm
            case .hrv: record.hrvEstimateMs
            case .breathing: record.breathingRatePerMinute
            }
            return value.flatMap { $0.isFinite ? $0 : nil }
        }
    }
    private struct Daily: Identifiable { let id: Date; let mean: Double }
    private var daily: [Daily] {
        let calendar = SleepCalendar.calendar(timeZone: timeZone)
        let days = Dictionary(grouping: records) { calendar.startOfDay(for: Date(timeIntervalSince1970: $0.timestamp)) }
        return days.compactMap { date, rows in
            let values = rows.compactMap(metric.value)
            return values.isEmpty ? nil : Daily(id: date, mean: values.reduce(0, +) / Double(values.count))
        }.sorted { $0.id < $1.id }
    }
    var body: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Imported measurements").font(.headline)
                Text("\(sideName) · \(records.count.formatted()) vital readings").font(.subheadline).foregroundStyle(Theme.text2)
                Picker("Measurement", selection: $metric) {
                    ForEach(Metric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu).accessibilityIdentifier("analysis.measurement")
                if daily.isEmpty {
                    Text("This archive has no \(metric.rawValue.lowercased()) readings for this side.").font(.subheadline).foregroundStyle(Theme.text2)
                } else {
                    Chart(daily) { day in
                        LineMark(x: .value("Day", day.id), y: .value(metric.unit, day.mean)).foregroundStyle(Theme.cool)
                        PointMark(x: .value("Day", day.id), y: .value(metric.unit, day.mean)).foregroundStyle(Theme.cool)
                    }.frame(height: chartHeight).chartYAxisLabel(metric.unit)
                        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                        .accessibilityLabel("Imported \(metric.rawValue.lowercased()) daily averages")
                    if let first = daily.first?.id, let last = daily.last?.id {
                        Text("\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted)) · daily averages")
                            .font(.caption).foregroundStyle(Theme.text3)
                    }
                }
                Text("Original Pod measurements, kept separate from Apple Health. Imported HRV retains its original estimator and is not interchangeable with Apple Watch HRV.")
                    .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }.padding(16)
        }.accessibilityIdentifier("analysis.importedMeasurements")
    }
}
