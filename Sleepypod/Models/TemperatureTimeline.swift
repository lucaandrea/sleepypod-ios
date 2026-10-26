import Foundation

/// A read-only projection of saved schedules in the Pod's timezone.
/// It never estimates Autopilot decisions or converts an unknown value into live telemetry.
struct TemperatureTimeline {
    struct Event: Identifiable, Sendable {
        let side: Side
        let date: Date
        let temperature: Int?
        let powered: Bool?
        var id: String { "\(side.rawValue)-\(date.timeIntervalSince1970)-\(powered.map(String.init) ?? "temp")" }
    }
    struct State: Equatable {
        var temperature: Int?
        var powered: Bool?
    }
    let range: ClosedRange<Date>
    let events: [Event]

    init(schedules: Schedules?, timezone: String, now: Date = .now) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        let today = calendar.startOfDay(for: now)
        let nightDay = calendar.component(.hour, from: now) < 9 ? calendar.date(byAdding: .day, value: -1, to: today)! : today
        let start = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: nightDay)!
        let nextDay = calendar.date(byAdding: .day, value: 1, to: nightDay)!
        let end = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: nextDay)!
        range = start...end
        var result: [Event] = []
        if let schedules {
            for dayOffset in -1...1 {
                let day = calendar.date(byAdding: .day, value: dayOffset, to: nightDay)!
                let weekday = DayOfWeek.allCases[calendar.component(.weekday, from: day) - 1]
                for side in Side.allCases {
                    let schedule = schedules.schedule(for: side)[weekday]
                    for (clock, temperature) in schedule.temperatures {
                        if let date = Self.date(clock, on: day, calendar: calendar) {
                            result.append(Event(side: side, date: date, temperature: temperature, powered: nil))
                        }
                    }
                    if schedule.power.enabled, let on = Self.date(schedule.power.on, on: day, calendar: calendar) {
                        result.append(Event(side: side, date: on, temperature: schedule.power.onTemperature, powered: true))
                        if schedule.power.endAction != .maintain,
                           let offMinutes = AlarmDraft.clockMinutes(schedule.power.off), let onMinutes = AlarmDraft.clockMinutes(schedule.power.on) {
                            let offset = schedule.power.offDayOffset ?? (offMinutes <= onMinutes ? 1 : 0)
                            // Resolve the off clock on its actual calendar day; shifting a DST-adjusted
                            // clock from the on day can otherwise carry the wrong hour into tomorrow.
                            if (0...1).contains(offset), let offDay = calendar.date(byAdding: .day, value: offset, to: day),
                               let off = Self.date(schedule.power.off, on: offDay, calendar: calendar) {
                                result.append(Event(side: side, date: off, temperature: nil, powered: false))
                            }
                        }
                    }
                }
            }
        }
        events = result.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            // An explicit setpoint at the same instant wins over a power-on default.
            return $0.powered != nil && $1.powered == nil
        }
    }

    func state(for side: Side, at date: Date) -> State {
        var state = State()
        for event in events where event.side == side && event.date <= date {
            if let temperature = event.temperature { state.temperature = temperature }
            if let powered = event.powered { state.powered = powered }
        }
        return state
    }
    struct Sample: Identifiable {
        let id: Int
        let date: Date
        let temperature: Int
    }

    /// Explicit pairs at each event keep the plotted step aligned with the real change time.
    func samples(for side: Side) -> [Sample] {
        var result: [Sample] = []
        var previous = state(for: side, at: range.lowerBound).temperature
        if let previous { result.append(Sample(id: result.count, date: range.lowerBound, temperature: previous)) }
        for event in events where event.side == side && event.date > range.lowerBound && event.date <= range.upperBound {
            guard let next = event.temperature else { continue }
            if let previous { result.append(Sample(id: result.count, date: event.date, temperature: previous)) }
            result.append(Sample(id: result.count, date: event.date, temperature: next))
            previous = next
        }
        if let previous { result.append(Sample(id: result.count, date: range.upperBound, temperature: previous)) }
        return result
    }

    func date(at fraction: Double) -> Date {
        range.lowerBound.addingTimeInterval(range.upperBound.timeIntervalSince(range.lowerBound) * min(1, max(0, fraction)))
    }
    static func date(_ clock: String, on day: Date, calendar: Calendar) -> Date? {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        // Resolve wall time using both offsets, matching Core's cron expansion. Foundation's
        // setting-hour shortcut can drop the requested minutes when that hour does not exist.
        let midnight = calendar.startOfDay(for: day)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: midnight) else { return nil }
        var wall = calendar.dateComponents([.year, .month, .day], from: day)
        wall.hour = parts[0]; wall.minute = parts[1]; wall.second = 0
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let nominal = utc.date(from: wall) else { return nil }
        let before = calendar.timeZone.secondsFromGMT(for: midnight.addingTimeInterval(-3 * 3600))
        let after = calendar.timeZone.secondsFromGMT(for: nextDay.addingTimeInterval(-1))
        let candidates = Set([before, after]).map { nominal.addingTimeInterval(-Double($0)) }.filter { candidate in
            calendar.isDate(candidate, inSameDayAs: day)
                && calendar.component(.hour, from: candidate) == parts[0]
                && calendar.component(.minute, from: candidate) == parts[1]
        }
        if let first = candidates.min() { return first }
        // Ordinary spring gaps move forward without losing minutes. Midnight gaps are skipped.
        let shifted = nominal.addingTimeInterval(-Double(before))
        return parts[0] != 0 && calendar.isDate(shifted, inSameDayAs: day) ? shifted : nil
    }
}
