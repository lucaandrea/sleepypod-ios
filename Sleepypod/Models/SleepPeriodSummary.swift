import Foundation

struct SleepNightSummary: Identifiable, Sendable {
    let day: Date
    let records: [SleepRecord]
    let metrics: [BiometricMetric: BiometricPlot.Stats]
    let metricSources: [BiometricMetric: String]
    var id: Date { day }
    var main: SleepRecord? { records.max { $0.sleepPeriodSeconds < $1.sleepPeriodSeconds } }
    var seconds: Int { NightRecordingSummary(records: records).recordedSeconds }
    var exits: Int { records.reduce(0) { $0 + max(0, $1.timesExitedBed) } }
}

struct SleepNightStageSummary: Sendable {
    let epochs: [SleepAnalyzer.SleepEpoch]
    let quality: Int?
    let source: String
    var asleepSeconds: Double { epochs.filter { $0.stage != .wake }.reduce(0) { $0 + $1.duration } }
    func fraction(_ stage: SleepAnalyzer.SleepStage) -> Double {
        guard asleepSeconds > 0 else { return 0 }
        return epochs.filter { $0.stage == stage }.reduce(0) { $0 + $1.duration } / asleepSeconds
    }
}

enum SleepPeriodSummary {
    /// Summarize every recorded interval without treating gaps as sleep.
    static func nights(days: [Date], records: [SleepRecord], vitals: [VitalsRecord], side: Side, calendar: Calendar) -> [SleepNightSummary] {
        let groups = Dictionary(grouping: records.filter { $0.side == side.rawValue }) { SleepCalendar.nightDate(for: $0.enteredBedDate, calendar: calendar) }
        return days.map { day in
            let records = groups[calendar.startOfDay(for: day)] ?? []
            let intervals = NightRecordingSummary(records: records).intervals
            let readings = vitals.filter { reading in
                reading.side == side.rawValue && intervals.contains { reading.date >= $0.start && reading.date < $0.end }
            }
            let metrics = Dictionary(uniqueKeysWithValues: BiometricMetric.allCases.compactMap { metric in
                BiometricPlot(metric: metric, records: readings).stats.map { (metric, $0) }
            })
            let sources = Dictionary(uniqueKeysWithValues: BiometricMetric.allCases.compactMap { metric -> (BiometricMetric, String)? in
                guard metrics[metric] != nil, let reading = readings.first(where: { metric.value($0) != nil }) else { return nil }
                return (metric, reading.sourceKey + (metric == .hrv ? ":" + (reading.hrvMetricID ?? "unknown") : ""))
            })
            return SleepNightSummary(day: calendar.startOfDay(for: day), records: records, metrics: metrics, metricSources: sources)
        }
    }
    static func stages(nights: [SleepNightSummary], summaries: [Int: SleepNightStageSummary]) -> [Int: SleepNightStageSummary] {
        Dictionary(uniqueKeysWithValues: nights.compactMap { night in
            guard let main = night.main else { return nil }
            let available = night.records.compactMap { summaries[$0.id] }
            let source = Set(available.map(\.source)).sorted().joined(separator: " · ")
            let coverage = available.count == night.records.count ? "" : " · \(available.count)/\(night.records.count) segments"
            return (main.id, .init(epochs: NightStageCoverage.epochs(available.flatMap(\.epochs),
                    within: NightRecordingSummary(records: night.records).intervals),
                quality: night.records.count == 1 ? available.first?.quality : nil, source: source + coverage))
        })
    }
    static func average(_ values: [Double]) -> Double? {
        let finite = values.filter(\.isFinite)
        return finite.isEmpty ? nil : finite.reduce(0, +) / Double(finite.count)
    }
    /// Measure clocks from noon, so 11 pm and 1 am average to midnight in the Pod's timezone.
    static func averageClock(_ dates: [Date], calendar: Calendar) -> Date? {
        guard let first = dates.first else { return nil }
        let minutes = dates.map { Double((calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0) + 720) % 1440) }
        let result = (Int((average(minutes) ?? 0).rounded()) + 720) % 1440
        return calendar.date(bySettingHour: result / 60, minute: result % 60, second: 0, of: first)
    }
    static func monthDays(containing date: Date, calendar: Calendar) -> [Date] {
        guard let start = calendar.dateInterval(of: .month, for: date)?.start,
              let days = calendar.range(of: .day, in: .month, for: date) else { return [] }
        return days.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: start) }
    }
    static func monthCells(days: [Date], calendar: Calendar) -> [Date?] {
        guard let first = days.first else { return [] }
        let blanks = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: blanks) + days.map(Optional.some)
    }
}
