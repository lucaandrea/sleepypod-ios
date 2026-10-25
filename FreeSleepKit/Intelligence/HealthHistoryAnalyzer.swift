import Foundation

enum HealthHistoryAnalyzer {
    // A noon-to-noon bucket keeps an overnight sleep together through midnight and daylight saving changes.
    static func bucket(for date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        return date < noon ? calendar.date(byAdding: .day, value: -1, to: noon) ?? noon : noon
    }
    static func build(samples: [HistoricalSleepSample], now: Date, timeZone: TimeZone) -> HealthHistory {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        var grouped: [String: [Date: [HistoricalSleepSample]]] = [:]
        var names: [String: String] = [:]
        var ignored = 0
        for sample in samples {
            guard sample.end > sample.start, sample.end <= now, sample.end.timeIntervalSince(sample.start) < 36 * 3600 else { ignored += 1; continue }
            names[sample.sourceID] = sample.sourceName
            var cursor = sample.start
            while cursor < sample.end {
                let bucket = bucket(for: cursor, calendar: calendar)
                guard let next = calendar.date(byAdding: .day, value: 1, to: bucket), next > cursor else { break }
                let end = min(next, sample.end)
                var part = sample; part.start = cursor; part.end = end
                grouped[sample.sourceID, default: [:]][bucket, default: []].append(part)
                cursor = end
            }
        }
        var sources: [HealthHistory.Source] = []
        for (sourceID, days) in grouped {
            var nights: [HealthHistory.Night] = []
            for (start, values) in days {
                let range = DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start) ?? start)
                func minutes(_ selected: [HistoricalSleepSample]) -> Double? {
                    HealthComparison.mergedMinutes(selected.map { DateInterval(start: $0.start, end: $0.end) }, within: range)
                }
                let night = HealthHistory.Night(id: start.ISO8601Format(), start: values.map(\.start).min() ?? start,
                    end: values.map(\.end).max() ?? start, asleepMinutes: minutes(values) ?? 0,
                    deepMinutes: minutes(values.filter { $0.stage == .deep }), remMinutes: minutes(values.filter { $0.stage == .rem }))
                nights.append(night)
            }
            sources.append(.init(id: sourceID, name: names[sourceID] ?? sourceID, nights: nights.sorted { $0.start < $1.start }))
        }
        sources.sort { first, second in
            first.nights.count == second.nights.count ? first.id < second.id : first.nights.count > second.nights.count
        }
        return HealthHistory(importedAt: now, timeZone: timeZone.identifier, sources: sources, ignoredSamples: ignored)
    }
    static func median(_ values: [Double]) -> Double? {
        let values = values.filter(\.isFinite).sorted()
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    }
    static func bedtimeMinute(_ date: Date, timeZone: TimeZone) -> Double {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return Double(minute < 720 ? minute + 1440 : minute)
    }
    static func facts(source: HealthHistory.Source?, now: Date, timeZone: TimeZone) -> [SleepFact] {
        guard let source, !source.nights.isEmpty else { return [] }
        let nights = source.nights
        let recent = nights.filter { $0.end > now.addingTimeInterval(-28 * 86400) }
        let week = recent.filter { $0.end > now.addingTimeInterval(-7 * 86400) }
        let prior = nights.filter { $0.end <= now.addingTimeInterval(-7 * 86400) && $0.end > now.addingTimeInterval(-35 * 86400) }
        var facts = [SleepFact(id: "health.coverage", text: "\(nights.count) noon-to-noon days with recorded sleep, \(nights.first!.start.formatted(date: .abbreviated, time: .omitted)) through \(nights.last!.end.formatted(date: .abbreviated, time: .omitted)). Source: \(source.name)."),
            SleepFact(id: "health.recent", text: "\(recent.count) recorded days in the last 28 days; \(week.count) in the last 7. Missing days are unknown, not zero sleep.")]
        func add(_ identifier: String, _ values: [Double], _ name: String, _ unit: String) {
            guard values.count >= 3, let value = median(values) else { return }
            facts.append(.init(id: identifier, text: "\(name): median \(value.formatted(.number.precision(.fractionLength(0...1)))) \(unit), from \(values.count) days in the last 28 days."))
        }
        add("health.sleep", recent.map(\.asleepMinutes), "Recorded sleep", "minutes per noon-to-noon day")
        add("health.rhr", recent.compactMap(\.restingHeartRate), "Daily resting heart rate", "bpm")
        add("health.hrv", recent.compactMap(\.hrv), "Daily HRV (SDNN)", "ms")
        add("health.respiration", recent.compactMap(\.respiratoryRate), "Daily respiratory rate", "breaths/min")
        if recent.count >= 7, let bedtime = median(recent.map { bedtimeMinute($0.start, timeZone: timeZone) }) {
            let variance = median(recent.map { abs(bedtimeMinute($0.start, timeZone: timeZone) - bedtime) }) ?? 0
            let minute = Int(bedtime) % 1440
            facts.append(.init(id: "health.timing", text: "Median first recorded sleep: \(minute / 60):\(String(format: "%02d", minute % 60)) in \(timeZone.identifier); median deviation \(Int(variance)) minutes. Naps can affect this measure."))
        }
        if week.count >= 4, prior.count >= 7, let latest = median(week.map(\.asleepMinutes)), let previous = median(prior.map(\.asleepMinutes)) {
            facts.append(.init(id: "health.change", text: "Recent 7-day median recorded sleep changed by \(Int((latest - previous).rounded())) minutes versus the preceding 28 days (\(week.count) versus \(prior.count) observed days). This is not evidence of a treatment effect."))
        }
        return facts
    }
}
