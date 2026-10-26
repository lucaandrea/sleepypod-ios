import Foundation

struct BedtimeRoutineDraft: Codable, Equatable, Sendable {
    struct Power: Codable, Equatable, Sendable {
        var onTime: String
        var offTime: String
        var onTemperature: Int
        var enabled: Bool
        var endAction: ScheduleEndAction
    }
    struct Temperature: Codable, Equatable, Sendable { var time: String; var temperature: Int; var enabled: Bool }
    struct Alarm: Codable, Equatable, Sendable {
        var time: String
        var vibrationIntensity: Int
        var vibrationPattern: VibrationPattern
        var duration: Int
        var alarmTemperature: Int
        var wakeWindow: Int
        var enabled: Bool
        var snoozeDuration: Int?
        var snoozeTaper: Int?
        static var standard: Self { .init(time: "07:00", vibrationIntensity: 50, vibrationPattern: .rise, duration: 10, alarmTemperature: 74, wakeWindow: 0, enabled: true, snoozeDuration: 300, snoozeTaper: 0) }
    }
    var power: Power
    var temperatures: [Temperature]
    var alarm: Alarm?
    var notes: String
    enum CodingKeys: String, CodingKey { case power, temperatures, alarm, notes }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(power, forKey: .power); try values.encode(temperatures, forKey: .temperatures)
        try values.encode(alarm, forKey: .alarm); try values.encode(notes, forKey: .notes)
    }
    static var blank: Self { .init(power: .init(onTime: "22:00", offTime: "07:00", onTemperature: 74, enabled: false, endAction: .turnOff), temperatures: [], alarm: nil, notes: "") }
    var normalized: Self {
        var result = self
        result.temperatures.sort { BedtimeRoutineTime.offset($0.time, from: power.onTime) < BedtimeRoutineTime.offset($1.time, from: power.onTime) }
        result.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.alarm != nil { result.alarm!.snoozeDuration = alarm?.snoozeDuration ?? 300; result.alarm!.snoozeTaper = alarm?.snoozeTaper ?? 0 }
        return result
    }
    func validate() throws {
        guard BedtimeRoutineTime.minutes(power.onTime) != nil, BedtimeRoutineTime.minutes(power.offTime) != nil,
              (55...110).contains(power.onTemperature), temperatures.count <= 96, notes.utf16.count <= 1000 else {
            throw BedtimeRoutineTime.error("Use valid times, temperatures from 55–110°F, up to 96 phases and notes up to 1,000 characters.")
        }
        let duration = BedtimeRoutineTime.offset(power.offTime, from: power.onTime)
        guard !power.enabled || duration != 0 else { throw BedtimeRoutineTime.error("Power-on and end time must differ.") }
        var times = Set<String>()
        for point in temperatures {
            guard BedtimeRoutineTime.minutes(point.time) != nil, (55...110).contains(point.temperature), times.insert(point.time).inserted else {
                throw BedtimeRoutineTime.error("Each temperature phase needs a valid, distinct time and a temperature from 55–110°F.")
            }
            let offset = BedtimeRoutineTime.offset(point.time, from: power.onTime)
            guard !point.enabled || (offset > 0 && offset < duration) else { throw BedtimeRoutineTime.error("Enabled temperature phases must fall between power-on and the end time.") }
        }
        if let alarm {
            guard BedtimeRoutineTime.minutes(alarm.time) != nil, (1...100).contains(alarm.vibrationIntensity), (10...180).contains(alarm.duration),
                  (55...110).contains(alarm.alarmTemperature), [0, 10, 15, 20, 30].contains(alarm.wakeWindow),
                  (60...1800).contains(alarm.snoozeDuration ?? 300), [0, 30, 40, 50, 60].contains(alarm.snoozeTaper ?? 0) else {
                throw BedtimeRoutineTime.error("Check the alarm time, temperature, vibration duration and snooze settings.")
            }
        }
    }
}
struct BedtimeRoutineSnapshot: Codable, Equatable, Identifiable, Sendable {
    let dayOfWeek: DayOfWeek
    let revision: String
    let draft: BedtimeRoutineDraft
    var id: DayOfWeek { dayOfWeek }
}
struct BedtimeRoutineBook: Codable, Sendable {
    let version: Int
    let side: Side
    let canCreate: Bool
    let routines: [BedtimeRoutineSnapshot]
    func validate(side expected: Side) throws {
        guard version == 1, side == expected, routines.count <= 7, Set(routines.map(\.dayOfWeek)).count == routines.count,
              routines.allSatisfy({ BedtimeRoutineTime.validRevision($0.revision) }) else { throw BedtimeRoutineTime.error("The routine response does not match this side. Reload before editing.") }
        try BedtimeRoutineTime.validateWeek(routines.map { ($0.dayOfWeek, $0.draft) })
    }
}
struct BedtimeRoutineChange: Codable, Equatable, Sendable {
    let dayOfWeek: DayOfWeek
    let expectedRevision: String?
    let replacement: BedtimeRoutineDraft?
    enum CodingKeys: String, CodingKey { case dayOfWeek, expectedRevision, replacement }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(dayOfWeek, forKey: .dayOfWeek); try values.encode(expectedRevision, forKey: .expectedRevision); try values.encode(replacement, forKey: .replacement)
    }
}
struct BedtimeRoutineChanges: Codable, Equatable, Sendable {
    let side: Side
    let changes: [BedtimeRoutineChange]
    func validate(against book: BedtimeRoutineBook) throws {
        try book.validate(side: side)
        guard book.canCreate, !changes.isEmpty, changes.count <= 7, Set(changes.map(\.dayOfWeek)).count == changes.count else {
            throw BedtimeRoutineTime.error("Existing calendar schedules must be migrated before using the complete routine editor.")
        }
        for change in changes {
            guard change.expectedRevision == book.routines.first(where: { $0.dayOfWeek == change.dayOfWeek })?.revision else {
                throw BedtimeRoutineTime.error("The \(change.dayOfWeek.displayName) routine changed. Reload and review your draft.")
            }
            try change.replacement?.validate()
        }
        let affected = Set(changes.map(\.dayOfWeek))
        let retained = book.routines.filter { !affected.contains($0.dayOfWeek) }.map { ($0.dayOfWeek, $0.draft) }
        let replacements = changes.compactMap { change in change.replacement.map { (change.dayOfWeek, $0) } }
        try BedtimeRoutineTime.validateWeek(retained + replacements)
    }
}
struct BedtimeRoutineReceipt: Decodable, Sendable {
    let version: Int
    let side: Side
    let canCreate: Bool
    let routines: [BedtimeRoutineSnapshot]
    let schedulerApplied: Bool
    var book: BedtimeRoutineBook { .init(version: version, side: side, canCreate: canCreate, routines: routines) }
}

enum BedtimeRoutineTime {
    static func error(_ message: String) -> APIError { .serverError(message: message) }
    static func validRevision(_ value: String) -> Bool { value.utf8.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    static func minutes(_ value: String) -> Int? {
        guard value.range(of: #"^([01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) != nil else { return nil }
        let components = value.split(separator: ":").compactMap { Int($0) }; return components[0] * 60 + components[1]
    }
    static func offset(_ value: String, from start: String) -> Int { ((minutes(value) ?? 0) - (minutes(start) ?? 0) + 1440) % 1440 }
    static func eventDay(_ day: DayOfWeek, time: String, start: String) -> DayOfWeek {
        let index = DayOfWeek.allCases.firstIndex(of: day)!
        return DayOfWeek.allCases[(index + (time < start ? 1 : 0)) % 7]
    }
    /// Match Core's weekly overlap and duplicate-event checks, including the Saturday/Sunday seam.
    static func validateWeek(_ routines: [(DayOfWeek, BedtimeRoutineDraft)]) throws {
        let week = 7 * 1440
        var windows: [(start: Int, end: Int)] = [], events = Set<String>()
        func add(_ kind: String, day: DayOfWeek, time: String) throws {
            guard events.insert("\(kind):\(day.rawValue):\(time)").inserted else { throw error("Two enabled routines have a \(kind) event on \(day.displayName) at \(time).") }
        }
        for (day, draft) in routines {
            try draft.validate()
            guard draft.power.enabled else { continue }
            let start = DayOfWeek.allCases.firstIndex(of: day)! * 1440 + minutes(draft.power.onTime)!
            let end = start + offset(draft.power.offTime, from: draft.power.onTime)
            for window in windows {
                for shift in [-week, 0, week] where start < window.end + shift && end > window.start + shift {
                    throw error("Enabled bedtime routines overlap. Shorten a routine or choose different nights.")
                }
            }
            windows.append((start, end)); try add("power", day: day, time: draft.power.onTime)
            if draft.power.endAction == .turnOff { try add("power", day: eventDay(day, time: draft.power.offTime, start: draft.power.onTime), time: draft.power.offTime) }
            for point in draft.temperatures where point.enabled { try add("temperature", day: eventDay(day, time: point.time, start: draft.power.onTime), time: point.time) }
            if let alarm = draft.alarm, alarm.enabled { try add("alarm", day: eventDay(day, time: alarm.time, start: draft.power.onTime), time: alarm.time) }
        }
    }
}
