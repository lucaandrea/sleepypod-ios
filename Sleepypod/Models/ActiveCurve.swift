import Foundation

/// The saved base plan. Live overrides and measured temperatures remain separate.
struct ActiveCurve: Identifiable {
    enum Source { case runOnce, schedule }
    let id: String
    let source: Source
    let session: RunOnceSession?
    let setPoints: [RunOnceSetPoint]
    let wakeTime: String
    let bedtime: String

    var constantTemperature: Int? {
        guard let first = setPoints.first, setPoints.allSatisfy({ $0.temperature == first.temperature }) else { return nil }
        return Int(first.temperature)
    }

    /// Keep the previous bedtime's plan until 9 AM, using the Pod's calendar.
    static func recurring(schedules: Schedules, side: Side, timezone: String, now: Date = .now) -> ActiveCurve? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        let today = calendar.startOfDay(for: now)
        guard let night = calendar.date(byAdding: .day, value: calendar.component(.hour, from: now) < 9 ? -1 : 0, to: today),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: night) else { return nil }
        let weekday = DayOfWeek.allCases[calendar.component(.weekday, from: night) - 1]
        let nextWeekday = DayOfWeek.allCases[calendar.component(.weekday, from: tomorrow) - 1]
        let saved = schedules.schedule(for: side)
        let daily = saved[weekday]
        var temperatures = daily.temperatures
        if saved.coreSnapshot != nil {
            // Core rows belong to calendar days; legacy Free Sleep rows belong to a night.
            temperatures = daily.temperatures.filter { (AlarmDraft.clockMinutes($0.key) ?? -1) >= 720 }
            for (clock, temperature) in saved[nextWeekday].temperatures where (AlarmDraft.clockMinutes(clock) ?? 1440) < 720 {
                temperatures[clock] = temperature
            }
        }
        var bedtime = "22:00", wake = "07:00"
        let enabledPowers = saved.coreSnapshot?.power.filter { $0.enabled && $0.dayOfWeek == weekday.rawValue }
        let power = enabledPowers?.count == 1 ? enabledPowers?.first?.summary : (saved.coreSnapshot == nil ? daily.power : nil)
        if let power, power.enabled,
           let onMinutes = AlarmDraft.clockMinutes(power.on), let offMinutes = AlarmDraft.clockMinutes(power.off) {
            let offset = power.offDayOffset ?? (saved.coreSnapshot == nil && offMinutes <= onMinutes ? 1 : 0)
            let duration = offMinutes + offset * 1440 - onMinutes
            // Do not invent a stop time for maintain mode, ambiguous rows, or a same-day legacy OFF.
            if power.endAction != .maintain, (0...1).contains(offset), duration > 0, duration <= 1440 {
                bedtime = power.on; wake = power.off
                temperatures = temperatures.filter {
                    guard let minutes = AlarmDraft.clockMinutes($0.key) else { return false }
                    return (minutes - onMinutes + 1440) % 1440 < duration
                }
                if temperatures[bedtime] == nil { temperatures[bedtime] = power.onTemperature }
            }
        }
        guard let start = AlarmDraft.clockMinutes(bedtime) else { return nil }
        let points = temperatures.compactMap { clock, temperature -> RunOnceSetPoint? in
            guard AlarmDraft.clockMinutes(clock) != nil else { return nil }
            return RunOnceSetPoint(time: clock, temperature: Double(temperature))
        }.sorted { (AlarmDraft.clockMinutes($0.time)! - start + 1440) % 1440 < (AlarmDraft.clockMinutes($1.time)! - start + 1440) % 1440 }
        guard !points.isEmpty else { return nil }
        return ActiveCurve(id: "schedule-\(side.rawValue)-\(weekday.rawValue)", source: .schedule, session: nil,
                           setPoints: points, wakeTime: wake, bedtime: bedtime)
    }
}
