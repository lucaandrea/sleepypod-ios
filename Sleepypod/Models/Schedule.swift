import Foundation

struct AlarmSchedule: Codable, Sendable, Equatable {
    var vibrationIntensity: Int
    var vibrationPattern: VibrationPattern
    var duration: Int
    var time: String  // "HH:mm"
    var enabled: Bool
    var alarmTemperature: Int
    var wakeWindow: Int?
    var snoozeDuration: Int?
    var snoozeTaper: Int?
}

enum VibrationPattern: String, Codable, Sendable {
    case double
    case rise
}

enum ScheduleEndAction: String, Codable, Sendable, CaseIterable {
    case turnOff = "turn_off"
    case maintain

    var label: String {
        self == .turnOff ? "Turn off" : "Maintain final temperature"
    }
}

struct PowerSchedule: Codable, Sendable, Equatable {
    var on: String   // "HH:mm"
    var off: String  // "HH:mm" — schedule boundary, even when maintaining
    // Optional so legacy cores and Free Sleep payloads continue to decode.
    var endAction: ScheduleEndAction?
    var offDayOffset: Int?
    var onTemperature: Int
    var enabled: Bool
}

struct DailySchedule: Codable, Sendable {
    var temperatures: [String: Int]  // "HH:mm" -> temperature °F
    var alarm: AlarmSchedule
    var power: PowerSchedule
}

struct SideSchedule: Codable, Sendable {
    var sunday: DailySchedule
    var monday: DailySchedule
    var tuesday: DailySchedule
    var wednesday: DailySchedule
    var thursday: DailySchedule
    var friday: DailySchedule
    var saturday: DailySchedule
    // Retain the complete Core rows so editing one native field cannot erase other rows.
    var coreSnapshot: CoreScheduleRows?

    subscript(day: DayOfWeek) -> DailySchedule {
        get {
            switch day {
            case .sunday: sunday
            case .monday: monday
            case .tuesday: tuesday
            case .wednesday: wednesday
            case .thursday: thursday
            case .friday: friday
            case .saturday: saturday
            }
        }
        set {
            switch day {
            case .sunday: sunday = newValue
            case .monday: monday = newValue
            case .tuesday: tuesday = newValue
            case .wednesday: wednesday = newValue
            case .thursday: thursday = newValue
            case .friday: friday = newValue
            case .saturday: saturday = newValue
            }
        }
    }
}

struct Schedules: Codable, Sendable {
    var left: SideSchedule
    var right: SideSchedule

    func schedule(for side: Side) -> SideSchedule {
        switch side {
        case .left: left
        case .right: right
        }
    }

    mutating func setSchedule(_ schedule: SideSchedule, for side: Side) {
        switch side {
        case .left: left = schedule
        case .right: right = schedule
        }
    }
}

enum DayOfWeek: String, CaseIterable, Codable, Sendable, Identifiable {
    case sunday, monday, tuesday, wednesday, thursday, friday, saturday

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .sunday: "S"
        case .monday: "M"
        case .tuesday: "T"
        case .wednesday: "W"
        case .thursday: "T"
        case .friday: "F"
        case .saturday: "S"
        }
    }

    var displayName: String {
        rawValue.capitalized
    }

    static var weekdays: [DayOfWeek] {
        [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
    }
}

struct AlarmJob: Codable, Sendable {
    var side: Side
    var vibrationIntensity: Int
    var vibrationPattern: VibrationPattern
    var duration: Int
    var force: Bool?
}

// Phase representation for the blocks view
struct SchedulePhase: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let icon: String
    let time: String      // "HH:mm"
    let temperatureF: Int

    var offset: Int {
        TemperatureConversion.tempFToOffset(temperatureF)
    }
}
