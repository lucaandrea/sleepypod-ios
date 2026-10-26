import Foundation

/// Recorded activity remains separate from saved targets and future rule eligibility.
struct TemperatureHistory {
    struct Interval: Identifiable, Equatable, Sendable {
        let start: Date
        let end: Date
        var id: Date { start }
    }
    struct RunOncePoint: Identifiable {
        let date: Date
        let temperature: Double
        var id: Date { date }
    }
    let range: ClosedRange<Date>
    let tonight: TemperatureTimeline
    let lastNight: TemperatureTimeline
    init(schedules: Schedules?, timezone: String, now: Date) {
        tonight = .init(schedules: schedules, timezone: timezone, now: now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        lastNight = .init(schedules: schedules, timezone: timezone, now: calendar.date(byAdding: .day, value: -1, to: now)!)
        range = lastNight.range.lowerBound...tonight.range.upperBound
    }
    /// Explicit reported intervals preserve exits. A malformed nonempty report never becomes continuous occupancy.
    static func presence(_ records: [SleepRecord], side: Side, in range: ClosedRange<Date>, now: Date) -> [Interval] {
        var intervals: [Interval] = []
        for record in records where record.side == side.rawValue {
            let end = min(record.completedAt ?? now, now)
            guard record.enteredBedDate.timeIntervalSince1970 > 0, end > record.enteredBedDate else { continue }
            if let raw = record.presentIntervals, !raw.isEmpty, raw != "null" {
                guard let data = raw.data(using: .utf8), let pairs = try? JSONDecoder().decode([[Double?]].self, from: data) else { continue }
                if pairs.isEmpty {
                    guard record.timesExitedBed == 0 else { continue }
                    intervals.append(.init(start: record.enteredBedDate, end: end))
                } else {
                    for pair in pairs where pair.count == 2 {
                        guard let start = pair[0], start.isFinite, start > 0, pair[1].map({ $0.isFinite && $0 > 0 }) ?? true else { continue }
                        let lower = Date(timeIntervalSince1970: start < 1e12 ? start : start / 1000)
                        let upper = pair[1].map { Date(timeIntervalSince1970: $0 < 1e12 ? $0 : $0 / 1000) } ?? end
                        intervals.append(.init(start: max(lower, record.enteredBedDate), end: min(upper, end)))
                    }
                }
            } else if record.timesExitedBed == 0 { intervals.append(.init(start: record.enteredBedDate, end: end)) }
        }
        return clipped(intervals, to: range, now: now)
    }
    /// A non-null historical target identifies a powered bucket. Missing intervals remain gaps.
    static func power(_ history: SystemThermalHistory, side: Side, in range: ClosedRange<Date>, now: Date) -> [Interval] {
        guard history.bucketSec.isFinite, history.bucketSec > 0, history.bucketSec <= 3600 else { return [] }
        let key: ThermalSignal = side == .left ? .leftTarget : .rightTarget
        let half = history.bucketSec / 2
        let intervals = history.points.sorted { $0.timestamp < $1.timestamp }.compactMap { point -> Interval? in
            guard point.timestamp.isFinite, point.timestamp > 0, let target = point.values[key], (55...110).contains(target) else { return nil }
            let center = Date(timeIntervalSince1970: point.timestamp / 1000)
            return .init(start: center.addingTimeInterval(-half), end: center.addingTimeInterval(half))
        }
        return clipped(intervals, to: range, now: now)
    }
    struct Comparison: Identifiable, Equatable {
        enum Kind: String { case laterEntry, laterExit }
        let kind: Kind
        let start: Date
        let end: Date
        var id: String { "\(kind.rawValue)-\(start.timeIntervalSince1970)" }
        var minutes: Int { Int((end.timeIntervalSince(start) / 60).rounded()) }
    }
    /// Compare recorded occupancy with current planned targets; this does not infer empty-bed heating.
    static func comparisons(timeline: TemperatureTimeline, side: Side, presence: [Interval]) -> [Comparison] {
        let targets = timeline.events.filter { $0.side == side && $0.temperature != nil && timeline.range.contains($0.date) }
        guard let first = targets.first, let last = targets.last, last.date > first.date else { return [] }
        let night = presence.filter { $0.end > first.date && $0.start < last.date.addingTimeInterval(6 * 3600) }
        guard let entered = night.map(\.start).min(), let left = night.map(\.end).max() else { return [] }
        var result: [Comparison] = []
        if entered.timeIntervalSince(first.date) >= 15 * 60 { result.append(.init(kind: .laterEntry, start: first.date, end: entered)) }
        if left.timeIntervalSince(last.date) >= 15 * 60 { result.append(.init(kind: .laterExit, start: last.date, end: left)) }
        return result
    }
    static func clipped(_ values: [Interval], to range: ClosedRange<Date>, now: Date) -> [Interval] {
        let sorted = values.map { Interval(start: max($0.start, range.lowerBound), end: min($0.end, range.upperBound, now)) }
            .filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var merged: [Interval] = []
        for value in sorted {
            if let last = merged.last, value.start <= last.end {
                merged[merged.count - 1] = .init(start: last.start, end: max(last.end, value.end))
            } else { merged.append(value) }
        }
        return merged
    }
    /// The first run-once target applies at start; later clocks follow Core's today-or-tomorrow scheduling rule.
    static func runOnce(_ session: RunOnceSession, side: Side, timezone: String) -> [RunOncePoint] {
        guard session.side == side.rawValue, session.status == "active", session.startedAt > 0,
              session.expiresAt > session.startedAt, session.setPoints.count <= 96,
              Set(session.setPoints.map(\.time)).count == session.setPoints.count,
              let first = session.setPoints.first, (55...110).contains(first.temperature) else { return [] }
        let start = Date(timeIntervalSince1970: Double(session.startedAt)), end = session.expiresAtDate
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        var result = [RunOncePoint(date: start, temperature: first.temperature)]
        for point in session.setPoints.dropFirst() {
            guard point.temperature.isFinite, (55...110).contains(point.temperature),
                  var date = TemperatureTimeline.date(point.time, on: start, calendar: calendar) else { return [] }
            if date <= start {
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: date) else { return [] }
                date = nextDay
            }
            if date < end { result.append(.init(date: date, temperature: point.temperature)) }
        }
        result.sort { $0.date < $1.date }
        if let last = result.last { result.append(.init(date: end, temperature: last.temperature)) }
        return result
    }
    static func runOnceTarget(_ points: [RunOncePoint], at date: Date) -> Double? {
        guard let first = points.first, let last = points.last, date >= first.date, date < last.date else { return nil }
        return points.last(where: { $0.date <= date })?.temperature
    }
}
