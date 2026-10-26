import Foundation

/// Mirrors Core's web phase grouping: before 04:00 belongs to the previous schedule day.
enum NightPhaseProjection {
    private struct Point { let time: String; let temperature: Double; let minute: Int }
    static func currentDay(now: Date, timezone: String) -> DayOfWeek {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        let day = calendar.component(.hour, from: now) < 4 ? calendar.date(byAdding: .day, value: -1, to: now)! : now
        return DayOfWeek.allCases[calendar.component(.weekday, from: day) - 1]
    }
    static func phases(rows: CoreScheduleRows, now: Date, timezone: String, draft: Bool = false) -> NightPhases? {
        let day = currentDay(now: now, timezone: timezone)
        let selected = rows.temperature.filter { $0.enabled && $0.dayOfWeek == day.rawValue }
        let points = ordered(selected)
        guard let first = points.first, let last = points.last else { return nil }
        let fingerprint = fingerprint(selected)
        let days = DayOfWeek.allCases.filter { candidate in
            candidate == day || (Self.fingerprint(rows.temperature.filter { $0.enabled && $0.dayOfWeek == candidate.rawValue }) == fingerprint && endAction(rows.power, day: candidate) == endAction(rows.power, day: day))
        }
        let span = last.minute - first.minute
        let threshold = Double(last.minute) - Double(span) * 0.25
        let split = points.count >= 2 && span > 0 ? points.firstIndex { Double($0.minute) >= threshold } ?? points.count : points.count
        let night = Array(points.prefix(split)), dawn = Array(points.dropFirst(split))
        guard !night.isEmpty else { return nil }
        return .init(draft: draft, day: day, days: days,
            night: phase(night, endMinute: dawn.first?.minute ?? last.minute + 30, endTime: dawn.first?.time ?? last.time),
            dawn: dawn.isEmpty ? nil : phase(dawn, endMinute: last.minute + 30, endTime: last.time))
    }
    static func shifted(rows: [CoreTemperatureRow], phases: NightPhases, targets: [NightPhaseKey: Int]) -> [CoreTemperatureRow] {
        var result = rows
        for (key, target) in targets {
            guard let phase = phases.phase(key) else { continue }
            let delta = target - Int(phase.temperatureF.rounded(.toNearestOrAwayFromZero))
            let times = Set(phase.times), days = Set(phases.days.map(\.rawValue))
            for index in result.indices where result[index].enabled && times.contains(result[index].time) && days.contains(result[index].dayOfWeek) {
                result[index].temperature = min(110, max(55, floor(result[index].temperature + Double(delta) + 0.5)))
            }
        }
        return result
    }
    static func validate(_ rows: CoreScheduleRows, side: Side) throws {
        guard Set(rows.temperature.map(\.id)).count == rows.temperature.count,
              rows.temperature.allSatisfy({ $0.id > 0 && $0.side == side.rawValue && DayOfWeek(rawValue: $0.dayOfWeek) != nil && AutomationCondition.validClock($0.time) && (55...110).contains($0.temperature) }),
              rows.power.allSatisfy({ $0.id > 0 && $0.side == side.rawValue && DayOfWeek(rawValue: $0.dayOfWeek) != nil && AutomationCondition.validClock($0.onTime) && AutomationCondition.validClock($0.offTime) }) else {
            throw APIError.serverError(message: "The controller returned an invalid nightly schedule. Reload before editing.")
        }
    }
    private static func fingerprint(_ rows: [CoreTemperatureRow]) -> [String] { rows.map { "\($0.time)@\($0.temperature)" }.sorted() }
    private static func endAction(_ rows: [CorePowerRow], day: DayOfWeek) -> ScheduleEndAction {
        let selected = rows.filter { $0.dayOfWeek == day.rawValue }
        return !selected.isEmpty && selected.allSatisfy { $0.endAction == .maintain } ? .maintain : .turnOff
    }
    private static func ordered(_ rows: [CoreTemperatureRow]) -> [Point] {
        let sorted = rows.filter { AutomationCondition.validClock($0.time) }.map { Point(time: $0.time, temperature: $0.temperature, minute: DisplayTime.minutes($0.time)) }.sorted { $0.minute < $1.minute }
        let wraps = zip(sorted, sorted.dropFirst()).contains { $1.minute - $0.minute > 720 }
        return sorted.map { Point(time: $0.time, temperature: $0.temperature, minute: $0.minute + (wraps && $0.minute < 720 ? 1440 : 0)) }.sorted { $0.minute < $1.minute }
    }
    private static func phase(_ points: [Point], endMinute: Int, endTime: String) -> NightPhase {
        var weighted = 0.0, total = 0.0
        for (index, point) in points.enumerated() {
            let duration = Double(max(1, (index + 1 < points.count ? points[index + 1].minute : endMinute) - point.minute))
            weighted += point.temperature * duration; total += duration
        }
        return .init(temperatureF: weighted / total, start: points[0].time, end: endTime, minutes: Double(max(1, endMinute - points[0].minute)), times: points.map(\.time))
    }
}
