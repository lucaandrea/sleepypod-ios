import Foundation

struct AlarmGroup: Identifiable, Equatable, Sendable {
    var rows: [CoreAlarmRow]
    var id: String { rows.map(\.id).sorted().map(String.init).joined(separator: ",") }
    var alarm: CoreAlarmRow { rows[0] }
    var days: [DayOfWeek] { DayOfWeek.weekdays.filter { day in rows.contains { $0.dayOfWeek == day } } }
    var daysLabel: String {
        if days.count == 7 { return "Every day" }
        if Set(days) == Set(DayOfWeek.weekdays.prefix(5)) { return "Weekdays" }
        if Set(days) == [.saturday, .sunday] { return "Weekends" }
        return days.map { String($0.displayName.prefix(3)) }.joined(separator: ", ")
    }
    static func group(_ rows: [CoreAlarmRow], side: Side) -> [Self] {
        var groups: [Self] = []
        for row in rows.filter({ $0.side == side }).sorted(by: { $0.id < $1.id }) {
            if let index = groups.firstIndex(where: { $0.alarm.summary == row.summary && $0.alarm.alarmTemperature == row.alarmTemperature }) { groups[index].rows.append(row) }
            else { groups.append(Self(rows: [row])) }
        }
        return groups.sorted { ($0.alarm.time, $0.alarm.id) < ($1.alarm.time, $1.alarm.id) }
    }
    /// Find the next enabled occurrence in the Pod's timezone, including DST transitions.
    func nextDate(after now: Date, timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        return rows.filter(\.enabled).compactMap { row -> Date? in
            guard let clock = AlarmDraft.clockMinutes(row.time), let weekday = DayOfWeek.allCases.firstIndex(of: row.dayOfWeek) else { return nil }
            return calendar.nextDate(after: now, matching: DateComponents(hour: clock / 60, minute: clock % 60, weekday: weekday + 1),
                                     matchingPolicy: .nextTime, repeatedTimePolicy: .first)
        }.min()
    }
}

struct AlarmDraft: Identifiable, Sendable {
    let id = UUID()
    var original: [CoreAlarmRow] = []
    var sides: Set<Side>
    var days: Set<DayOfWeek> = []
    var time = "07:00"
    var enabled = true
    var pattern = VibrationPattern.rise
    var intensity = 100
    var duration = 30
    var temperature = 75
    var wakeWindow = 0
    var snoozeDuration = 300
    var snoozeTaper = 0
    static let snoozeTapers = [0, 30, 40, 50, 60]
    static let wakeWindows = [0, 10, 15, 20, 30]

    init(sides: Set<Side>) { self.sides = sides }
    init(group: AlarmGroup) {
        original = group.rows; sides = [group.alarm.side]; days = Set(group.days)
        time = group.alarm.time; enabled = group.alarm.enabled; pattern = group.alarm.vibrationPattern
        intensity = group.alarm.vibrationIntensity; duration = group.alarm.duration
        temperature = Int(group.alarm.alarmTemperature.rounded()); wakeWindow = group.alarm.wakeWindow ?? 0
        snoozeDuration = group.alarm.snoozeDuration ?? 300; snoozeTaper = group.alarm.snoozeTaper ?? 0
    }
    var validation: String? {
        if sides.isEmpty { return "Choose at least one side." }
        if days.isEmpty { return "Choose at least one day." }
        if Self.clockMinutes(time) == nil { return "Enter a valid time." }
        if !(1...100).contains(intensity) || !(0...180).contains(duration) { return "Choose a valid vibration intensity and duration." }
        if !(55...110).contains(temperature) { return "Choose a temperature between 55°F and 110°F." }
        if !Self.wakeWindows.contains(wakeWindow) { return "Choose a supported wake window." }
        if !(60...1800).contains(snoozeDuration) || !Self.snoozeTapers.contains(snoozeTaper) { return "Choose a valid snooze length and taper." }
        return nil
    }
    var windowStart: String {
        let minutes = ((Self.clockMinutes(time) ?? 420) - wakeWindow + 1440) % 1440
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
    var snoozePreview: String {
        (0..<4).map { count in
            let seconds = max(5, Int((Double(snoozeDuration) * pow(1 - Double(snoozeTaper) / 100, Double(count))).rounded()))
            return (Double(seconds) / 60).formatted(.number.precision(.fractionLength(0...1)))
        }.joined(separator: ", ") + " min"
    }
    var creates: [AlarmCreate] {
        Side.allCases.filter { sides.contains($0) }.flatMap { side in
            DayOfWeek.allCases.filter { days.contains($0) }.map { day in
                AlarmCreate(side: side, dayOfWeek: day, time: time, vibrationIntensity: intensity,
                    vibrationPattern: pattern, duration: duration, alarmTemperature: Double(temperature), enabled: enabled, wakeWindow: wakeWindow, snoozeDuration: snoozeDuration, snoozeTaper: snoozeTaper)
            }
        }
    }
    static func clockMinutes(_ value: String) -> Int? {
        let parts = value.split(separator: ":")
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }
}

struct AlarmCreate: Encodable, Sendable {
    var side: Side
    var dayOfWeek: DayOfWeek
    var time: String
    var vibrationIntensity: Int
    var vibrationPattern: VibrationPattern
    var duration: Int
    var alarmTemperature: Double
    var enabled: Bool
    var wakeWindow: Int
    var snoozeDuration: Int?
    var snoozeTaper: Int?
    func row(id: Int) -> CoreAlarmRow {
        CoreAlarmRow(id: id, side: side, dayOfWeek: dayOfWeek, time: time, vibrationIntensity: vibrationIntensity,
            vibrationPattern: vibrationPattern, duration: duration, alarmTemperature: alarmTemperature, enabled: enabled, wakeWindow: wakeWindow, snoozeDuration: snoozeDuration, snoozeTaper: snoozeTaper)
    }
}

struct AlarmToggle: Encodable, Sendable { var id: Int; var enabled: Bool }
struct AlarmBatch: Encodable, Sendable {
    var creates: [AlarmCreate] = []
    var deletes: [Int] = []
    var updates: [AlarmToggle] = []
    enum CodingKeys: String, CodingKey { case creates, deletes, updates }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(["alarm": creates], forKey: .creates)
        try container.encode(["alarm": deletes], forKey: .deletes)
        try container.encode(["alarm": updates], forKey: .updates)
    }
}
