import Foundation

struct CoreTemperatureRow: Codable, Sendable, Equatable {
    var id: Int
    var side: String
    var dayOfWeek: String
    var time: String
    var temperature: Double
    var enabled: Bool
}

struct CorePowerRow: Codable, Sendable, Equatable {
    var id: Int
    var side: String
    var dayOfWeek: String
    var onTime: String
    var offTime: String
    var onTemperature: Double
    var enabled: Bool
    var endAction: ScheduleEndAction?
    var offDayOffset: Int?

    var summary: PowerSchedule {
        PowerSchedule(on: onTime, off: offTime, endAction: endAction, offDayOffset: offDayOffset,
                      onTemperature: Int(onTemperature), enabled: enabled)
    }
}

struct CoreAlarmRow: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var side: Side
    var dayOfWeek: DayOfWeek
    var time: String
    var vibrationIntensity: Int
    var vibrationPattern: VibrationPattern
    var duration: Int
    var alarmTemperature: Double
    var enabled: Bool
    var wakeWindow: Int?
    var snoozeDuration: Int?
    var snoozeTaper: Int?

    var summary: AlarmSchedule {
        AlarmSchedule(vibrationIntensity: vibrationIntensity, vibrationPattern: vibrationPattern, duration: duration,
                      time: time, enabled: enabled, alarmTemperature: Int(alarmTemperature), wakeWindow: wakeWindow, snoozeDuration: snoozeDuration, snoozeTaper: snoozeTaper)
    }
}

struct CoreScheduleRows: Codable, Sendable, Equatable {
    var temperature: [CoreTemperatureRow] = []
    var power: [CorePowerRow] = []
    var alarm: [CoreAlarmRow] = []

    static let emptyDay = DailySchedule(temperatures: [:],
        alarm: AlarmSchedule(vibrationIntensity: 50, vibrationPattern: .rise, duration: 30, time: "07:00", enabled: false, alarmTemperature: 80),
        power: PowerSchedule(on: "22:00", off: "07:00", onTemperature: 75, enabled: false))

    func representativeAlarm(on day: DayOfWeek) -> CoreAlarmRow? {
        let rows = alarm.filter { $0.dayOfWeek == day }.sorted { ($0.time, $0.id) < ($1.time, $1.id) }
        return rows.first { $0.enabled } ?? rows.first
    }

    /// The compact native curve uses one summary, but retains every original row for precise writes.
    var projected: SideSchedule {
        var days = Dictionary(uniqueKeysWithValues: DayOfWeek.allCases.map { ($0.rawValue, Self.emptyDay) })
        for row in temperature where row.enabled { days[row.dayOfWeek]?.temperatures[row.time] = Int(row.temperature) }
        for row in power { days[row.dayOfWeek]?.power = row.summary }
        for day in DayOfWeek.allCases {
            if let row = representativeAlarm(on: day) { days[day.rawValue]?.alarm = row.summary }
        }
        return SideSchedule(sunday: days["sunday"]!, monday: days["monday"]!, tuesday: days["tuesday"]!,
            wednesday: days["wednesday"]!, thursday: days["thursday"]!, friday: days["friday"]!, saturday: days["saturday"]!, coreSnapshot: self)
    }
}
