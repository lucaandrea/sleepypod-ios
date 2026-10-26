import Foundation

/// Read-only night plan. Temporal eligibility never predicts sensor conditions or actuator decisions.
struct AutomationTimeline {
    struct Block: Identifiable {
        let start: Date
        let end: Date
        let temperature: Int?
        var id: Date { start }
    }
    struct RuleLane: Identifiable {
        let rule: AutomationRule
        let windows: [DateInterval]
        var id: Int { rule.id }
    }
    let schedule: TemperatureTimeline
    let lanes: [RuleLane]
    var range: ClosedRange<Date> { schedule.range }

    init(schedules: Schedules?, rules: [AutomationRule], timezone: String, now: Date) {
        let projection = TemperatureTimeline(schedules: schedules, timezone: timezone, now: now)
        schedule = projection
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        lanes = rules.filter { $0.definition.enabled }.map {
            RuleLane(rule: $0, windows: Self.possibleWindows($0.definition.conditions, in: projection.range, calendar: calendar))
        }
    }

    func blocks(for side: Side) -> [Block] {
        let boundaries = Set([range.lowerBound, range.upperBound] + schedule.events.filter { $0.side == side && range.contains($0.date) }.map(\.date)).sorted()
        return zip(boundaries, boundaries.dropFirst()).compactMap { start, end in
            let state = schedule.state(for: side, at: start)
            guard state.powered == true else { return nil }
            return Block(start: start, end: end, temperature: state.temperature)
        }
    }

    static func affects(_ side: Side, rule: AutomationRule) -> Bool {
        rule.definition.actions.contains { action in
            if action.kind == .notify { return rule.definition.side == nil || rule.definition.side == side }
            let selected = action.side ?? rule.definition.side
            return selected == nil || selected == side
        }
    }

    /// Unknown sensor comparisons remain possible, including beneath NOT/OR. Time/day exclusions are exact to a minute.
    static func temporalMatch(_ condition: AutomationCondition, at date: Date, calendar: Calendar) -> Bool? {
        switch condition {
        case .all(let children):
            let values = children.map { temporalMatch($0, at: date, calendar: calendar) }
            if values.contains(false) { return false }
            return values.contains(nil) ? nil : true
        case .any(let children):
            let values = children.map { temporalMatch($0, at: date, calendar: calendar) }
            if values.contains(true) { return true }
            return values.contains(nil) ? nil : false
        case .not(let child): return temporalMatch(child, at: date, calendar: calendar).map { !$0 }
        case .time(let start, let end):
            guard AutomationCondition.validClock(start), AutomationCondition.validClock(end) else { return nil }
            let startMinute = DisplayTime.minutes(start); let endMinute = DisplayTime.minutes(end)
            let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
            if startMinute == endMinute { return false }
            return startMinute < endMinute ? (startMinute..<endMinute).contains(minute) : minute >= startMinute || minute < endMinute
        case .days(let days): return days.contains(DayOfWeek.allCases[calendar.component(.weekday, from: date) - 1])
        case .compare, .between: return nil
        }
    }

    static func possibleWindows(_ condition: AutomationCondition, in range: ClosedRange<Date>, calendar: Calendar) -> [DateInterval] {
        var windows: [DateInterval] = []
        var start: Date?
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            if temporalMatch(condition, at: cursor, calendar: calendar) != false {
                if start == nil { start = cursor }
            } else if let opened = start { windows.append(.init(start: opened, end: cursor)); start = nil }
            cursor = min(range.upperBound, cursor.addingTimeInterval(60))
        }
        if let start { windows.append(.init(start: start, end: range.upperBound)) }
        return windows
    }
}
