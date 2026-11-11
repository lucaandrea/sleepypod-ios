import Foundation

/// Frozen, source-specific observations for a report. Missing days are never zero-filled.
struct ReportSleepComparison: Codable, Sendable, Equatable {
    struct Day: Codable, Sendable, Equatable, Identifiable {
        var start: Date
        var end: Date
        var minutes: Double?
        var id: Date { start }
    }
    var sourceID: String
    var sourceName: String
    var timeZone: String
    var importedAt: Date
    var asOf: Date
    var days: [Day]
    var omittedRecords: Int

    var observedCount: Int { days.compactMap(\.minutes).count }
    var latest: Day? { days.last { $0.minutes != nil } }
    var priorValues: [Double] { days.prefix(7).compactMap(\.minutes) }
    var recentValues: [Double] { days.suffix(7).compactMap(\.minutes) }
    var medianChange: Double? {
        guard priorValues.count >= 4, recentValues.count >= 4,
              let prior = HealthHistoryAnalyzer.median(priorValues),
              let recent = HealthHistoryAnalyzer.median(recentValues) else { return nil }
        return recent - prior
    }

    /// Calendar days retain their actual length through DST; each point is one noon-to-noon bucket.
    static func capture(source: HealthHistory.Source?, history: HealthHistory, now: Date) -> Self? {
        guard let source, !source.id.isEmpty, let zone = TimeZone(identifier: history.timeZone),
              now.timeIntervalSince1970.isFinite, history.importedAt.timeIntervalSince1970.isFinite,
              history.importedAt > .distantPast, history.importedAt <= now else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let current = HealthHistoryAnalyzer.bucket(for: now, calendar: calendar)
        let starts = (-13...0).compactMap { calendar.date(byAdding: .day, value: $0, to: current) }
        guard starts.count == 14, let first = starts.first else { return nil }
        var grouped: [Date: [HealthHistory.Night]] = [:]
        var rejected = Set<Date>()
        let conflicts = Set(Dictionary(grouping: source.nights, by: \.id).compactMap { identifier, records in
            records.dropFirst().contains { $0 != records[0] } ? identifier : nil
        })
        var omitted = 0
        for night in source.nights where night.end > first && night.start <= now {
            guard night.start.timeIntervalSince1970.isFinite, night.end.timeIntervalSince1970.isFinite else { omitted += 1; continue }
            let bucket = HealthHistoryAnalyzer.bucket(for: night.start, calendar: calendar)
            guard let end = calendar.date(byAdding: .day, value: 1, to: bucket),
                  bucket >= first, night.start >= bucket, night.end <= end,
                  night.end > night.start, night.end <= history.importedAt, night.end <= now,
                  !conflicts.contains(night.id), night.asleepMinutes.isFinite, night.asleepMinutes > 0,
                  night.asleepMinutes <= night.end.timeIntervalSince(night.start) / 60 + 0.01 else {
                omitted += 1; rejected.insert(bucket); continue
            }
            if !(grouped[bucket] ?? []).contains(night) { grouped[bucket, default: []].append(night) }
        }
        let days = starts.compactMap { start -> Day? in
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            let nights = grouped[start] ?? []
            if nights.count > 1 { omitted += nights.count }
            return Day(start: start, end: end, minutes: nights.count == 1 && !rejected.contains(start) ? nights[0].asleepMinutes : nil)
        }
        return Self(sourceID: source.id, sourceName: source.name, timeZone: zone.identifier,
                    importedAt: history.importedAt, asOf: now, days: days, omittedRecords: omitted)
    }

    /// Stored optional metadata must be coherent before the view treats it as chart evidence.
    var isValid: Bool {
        guard !sourceID.isEmpty, let zone = TimeZone(identifier: timeZone), days.count == 14,
              omittedRecords >= 0, importedAt <= asOf, importedAt > .distantPast,
              asOf.timeIntervalSince1970.isFinite else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let current = HealthHistoryAnalyzer.bucket(for: asOf, calendar: calendar)
        return days.enumerated().allSatisfy { index, day in
            guard let start = calendar.date(byAdding: .day, value: index - 13, to: current),
                  let end = calendar.date(byAdding: .day, value: 1, to: start),
                  day.start == start, day.end == end else { return false }
            return day.minutes.map { $0.isFinite && $0 > 0 && $0 <= min(end, importedAt).timeIntervalSince(start) / 60 + 0.01 } ?? true
        }
    }

    func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: timeZone)
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
    static func duration(_ minutes: Double) -> String {
        let rounded = Int(minutes.rounded())
        return rounded >= 60 ? "\(rounded / 60)h \(rounded % 60)m" : "\(rounded)m"
    }
}
