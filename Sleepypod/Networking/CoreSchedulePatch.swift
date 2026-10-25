import Foundation

/// Translate a compact curve edit into changes to its own rows, preserving paused and extra schedules.
struct CoreSchedulePatch {
    private var temperatureDeletes: [Int] = []
    private var temperatureCreates: [[String: Any]] = []
    private var powerCreates: [[String: Any]] = []
    private var alarmCreates: [[String: Any]] = []
    private var temperatureUpdates: [[String: Any]] = []
    private var powerUpdates: [[String: Any]] = []
    private var alarmUpdates: [[String: Any]] = []

    var isEmpty: Bool { temperatureDeletes.isEmpty && temperatureCreates.isEmpty && powerCreates.isEmpty && alarmCreates.isEmpty && temperatureUpdates.isEmpty && powerUpdates.isEmpty && alarmUpdates.isEmpty }
    var input: [String: Any] {
        ["deletes": ["temperature": temperatureDeletes],
         "creates": ["temperature": temperatureCreates, "power": powerCreates, "alarm": alarmCreates],
         "updates": ["temperature": temperatureUpdates, "power": powerUpdates, "alarm": alarmUpdates]]
    }

    mutating func append(requested: SideSchedule, latest: CoreScheduleRows, side: Side, days: Set<DayOfWeek>) throws {
        let original = requested.coreSnapshot ?? latest
        let baseline = original.projected
        for day in DayOfWeek.allCases where days.contains(day) {
            let before = baseline[day], after = requested[day]
            if before.temperatures != after.temperatures {
                let oldRows = original.temperature.filter { $0.dayOfWeek == day.rawValue }
                try unchanged(oldRows, latest.temperature.filter { $0.dayOfWeek == day.rawValue })
                for time in Set(before.temperatures.keys).union(after.temperatures.keys).sorted() where before.temperatures[time] != after.temperatures[time] {
                    let matching = oldRows.filter { $0.time == time && $0.enabled }
                    if let value = after.temperatures[time] {
                        if matching.isEmpty {
                            temperatureCreates.append(["side": side.rawValue, "dayOfWeek": day.rawValue, "time": time, "temperature": value, "enabled": true])
                        } else {
                            temperatureUpdates += matching.map { ["id": $0.id, "temperature": value] }
                        }
                    } else { temperatureDeletes += matching.map(\.id) }
                }
            }
            if before.power != after.power {
                let oldRows = original.power.filter { $0.dayOfWeek == day.rawValue }
                try unchanged(oldRows, latest.power.filter { $0.dayOfWeek == day.rawValue })
                let power = after.power
                var fields: [String: Any] = ["onTime": power.on, "offTime": power.off, "onTemperature": power.onTemperature, "enabled": power.enabled]
                if let action = power.endAction { fields["endAction"] = action.rawValue }
                if power.offDayOffset != nil || power.endAction != nil {
                    // Preserve an explicit calendar offset; infer it only when the compact editor changes the clock.
                    let clocksChanged = before.power.on != power.on || before.power.off != power.off
                    fields["offDayOffset"] = !clocksChanged && power.offDayOffset != nil ? power.offDayOffset!
                        : (DisplayTime.minutes(power.off) <= DisplayTime.minutes(power.on) ? 1 : 0)
                }
                if let existing = oldRows.last { fields["id"] = existing.id; powerUpdates.append(fields) }
                else { fields["side"] = side.rawValue; fields["dayOfWeek"] = day.rawValue; powerCreates.append(fields) }
            }
            if before.alarm != after.alarm {
                let oldRows = original.alarm.filter { $0.dayOfWeek == day }
                try unchanged(oldRows, latest.alarm.filter { $0.dayOfWeek == day })
                let alarm = after.alarm
                var fields: [String: Any] = ["time": alarm.time, "vibrationIntensity": alarm.vibrationIntensity,
                    "vibrationPattern": alarm.vibrationPattern.rawValue, "duration": alarm.duration,
                    "alarmTemperature": alarm.alarmTemperature, "enabled": alarm.enabled]
                if let window = alarm.wakeWindow { fields["wakeWindow"] = window }
                if let duration = alarm.snoozeDuration { fields["snoozeDuration"] = duration }
                if let taper = alarm.snoozeTaper { fields["snoozeTaper"] = taper }
                if let existing = original.representativeAlarm(on: day) { fields["id"] = existing.id; alarmUpdates.append(fields) }
                else { fields["side"] = side.rawValue; fields["dayOfWeek"] = day.rawValue; alarmCreates.append(fields) }
            }
        }
        guard [temperatureDeletes.count, temperatureCreates.count, powerCreates.count, alarmCreates.count,
               temperatureUpdates.count, powerUpdates.count, alarmUpdates.count].allSatisfy({ $0 <= 1000 }) else {
            throw APIError.serverError(message: "This edit is too large. Select fewer days and try again.")
        }
    }
    private func unchanged<Row: Equatable>(_ original: [Row], _ latest: [Row]) throws {
        guard original == latest else { throw APIError.serverError(message: "The schedule changed on another device. Refresh and review it before saving again.") }
    }
}
