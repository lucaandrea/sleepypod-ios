import Foundation

typealias RoutineBook = [String: [String: DailySchedule]]

struct RoutineDraft {
    var original: DailySchedule
    var value: DailySchedule
    var copies: Set<String> = []
}
struct RoutineSave: Encodable, Sendable {
    var side: BedSide
    var days: [String]
    var schedule: DailySchedule
    var expected: [String: DailySchedule]
}
struct RoutinePoint: Identifiable {
    var time: String
    var minutes: Int
    var temperature: Int
    var id: String { time }
}

enum RoutinePlan {
    static let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    static func minutes(_ time: String) -> Int? {
        guard time.range(of: #"^([01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) != nil else { return nil }
        let parts = time.split(separator: ":").compactMap { Int($0) }
        return parts[0] * 60 + parts[1]
    }
    static func offset(_ time: String, from start: String) -> Int? {
        guard let end = minutes(time), let beginning = minutes(start) else { return nil }
        return (end - beginning + 1440) % 1440
    }
    static func problems(_ schedule: DailySchedule) -> [String] {
        guard let duration = offset(schedule.power.off, from: schedule.power.on), minutes(schedule.alarm.time) != nil,
              schedule.temperatures.keys.allSatisfy({ minutes($0) != nil }),
              ([schedule.power.onTemperature, schedule.alarm.alarmTemperature] + Array(schedule.temperatures.values)).allSatisfy({ (55...110).contains($0) }),
              (1...100).contains(schedule.alarm.vibrationIntensity), (1...180).contains(schedule.alarm.duration),
              ["rise", "double"].contains(schedule.alarm.vibrationPattern) else {
            return ["Use valid 24-hour times, temperatures from 55–110°F and valid alarm settings."]
        }
        if !schedule.power.enabled { return [] }
        var problems: [String] = []
        if duration == 0 { problems.append("Turn-on and turn-off times must be different.") }
        for time in schedule.temperatures.keys.sorted() {
            let position = offset(time, from: schedule.power.on) ?? -1
            if !(position > 0 && position < duration) { problems.append("Adjustment \(time) must fall between turn-on and turn-off.") }
        }
        if schedule.alarm.enabled {
            let position = offset(schedule.alarm.time, from: schedule.power.on) ?? -1
            if !(position > 0 && position < duration) { problems.append("The vibration alarm must fall between turn-on and turn-off.") }
        }
        return problems
    }
    static func points(_ schedule: DailySchedule) -> [RoutinePoint] {
        guard let duration = offset(schedule.power.off, from: schedule.power.on), duration > 0 else { return [] }
        var result = [RoutinePoint(time: schedule.power.on, minutes: 0, temperature: schedule.power.onTemperature)]
        result += schedule.temperatures.compactMap { time, temperature in
            guard let position = offset(time, from: schedule.power.on), position > 0, position < duration else { return nil }
            return RoutinePoint(time: time, minutes: position, temperature: temperature)
        }.sorted { $0.minutes < $1.minutes }
        result.append(.init(time: schedule.power.off, minutes: duration, temperature: result.last!.temperature))
        return result
    }
    static func hasCompleteWeek(_ book: RoutineBook) -> Bool {
        ["left", "right"].allSatisfy { side in days.allSatisfy { book[side]?[$0] != nil } }
    }
    static func apply(_ request: RoutineSave, to book: inout RoutineBook) throws {
        guard !request.days.isEmpty, Set(request.days).count == request.days.count,
              Set(request.days).isSubset(of: Set(days)), Set(request.expected.keys) == Set(request.days) else {
            throw PodError.message("Include the original routine for every selected day.")
        }
        for day in request.days {
            guard let expected = request.expected[day], book[request.side.rawValue]?[day] == expected else {
                throw PodError.message("\(day.capitalized) changed on another client. Reload saved routines before saving.")
            }
        }
        let errors = problems(request.schedule)
        guard errors.isEmpty else { throw PodError.message(errors.joined(separator: " ")) }
        for day in request.days { book[request.side.rawValue]?[day] = request.schedule }
    }
    // Demo recurrence follows the routine's starting weekday and Pod-local clock, including overnight alarms.
    static func nextAlarm(_ book: RoutineBook, side: BedSide, now: Date, timeZone: TimeZone) -> AlarmPreview.Occurrence? {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let candidates = days.enumerated().compactMap { index, day -> (Date, AlarmPreview.Occurrence)? in
            guard let routine = book[side.rawValue]?[day], routine.power.enabled, routine.alarm.enabled,
                  let clock = minutes(routine.alarm.time) else { return nil }
            var match = DateComponents()
            match.weekday = ((index + 1 + (routine.alarm.time < routine.power.on ? 1 : 0)) % 7) + 1
            match.hour = clock / 60; match.minute = clock % 60; match.second = 0
            guard let date = calendar.nextDate(after: now, matching: match, matchingPolicy: .nextTime) else { return nil }
            return (date, .init(at: date.ISO8601Format(), time: routine.alarm.time, scheduleDay: day, source: "routine"))
        }
        return candidates.min { $0.0 < $1.0 }?.1
    }
}
