import Foundation

struct SystemSchedulerTimeline: Decodable, Sendable {
    let enabled: Bool
    let timezone: String
    let now: Double
    let jobs: [Job]
    let occurrences: [Occurrence]

    struct Job: Decodable, Sendable, Identifiable {
        let id: String
        let type: String
        let side: Side?
        let schedule: String
        let oneTime: Bool
        let nextRun: Double?
        let targetTempF: Double?
        let brightness: Double?
        var group: Group { Group(type: type) }
    }
    struct Occurrence: Decodable, Sendable {
        let id: String
        let type: String
        let side: Side?
        let at: Double
        let targetTempF: Double?
        let brightness: Double?
        var date: Date { Date(timeIntervalSince1970: at / 1000) }
        var identity: String { "\(id):\(at)" }
    }
    enum Group: String, CaseIterable, Identifiable, Sendable {
        case temperature = "Temperature", power = "Power", alarm = "Alarms", maintenance = "Maintenance", other = "Other"
        var id: String { rawValue }
        init(type: String) {
            switch type {
            case "temperature", "run_once": self = .temperature
            case "power_on", "power_off": self = .power
            case "alarm": self = .alarm
            case "prime", "reboot", "calibration": self = .maintenance
            default: self = .other
            }
        }
    }
    struct Night: Identifiable, Sendable {
        let start: Date
        let end: Date
        let occurrences: [Occurrence]
        var id: Date { start }
    }
    struct TargetSpan: Identifiable, Sendable {
        let start: Date
        let end: Date
        let temperature: Double
        var id: Date { start }
    }
    var date: Date { Date(timeIntervalSince1970: now / 1000) }
    var validTimezone: Bool { TimeZone(identifier: timezone) != nil }
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .gmt
        return calendar
    }
    var upcoming: [Occurrence] { occurrences.filter { $0.at >= now }.sorted { $0.at < $1.at } }

    // Calendar noons preserve 23/25-hour nights across daylight-saving transitions.
    func nights(count: Int = 7) -> [Night] {
        let calendar = calendar
        guard let today = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date),
              let first = calendar.date(byAdding: .day, value: date < today ? -1 : 0, to: today) else { return [] }
        return (0..<max(0, count)).compactMap { offset in
            guard let start = calendar.date(byAdding: .day, value: offset, to: first),
                  let end = calendar.date(byAdding: .day, value: offset + 1, to: first) else { return nil }
            return Night(start: start, end: end, occurrences: occurrences.filter { $0.date >= start && $0.date < end }.sorted { $0.at < $1.at })
        }
    }

    func axis(for night: Night) -> ClosedRange<Date> {
        var start = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: night.start) ?? night.start
        var end = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: night.end) ?? night.end
        for occurrence in night.occurrences where occurrence.side != nil {
            if occurrence.date < start { start = calendar.dateInterval(of: .hour, for: occurrence.date)?.start ?? occurrence.date }
            if occurrence.date >= end { end = min(night.end, calendar.dateInterval(of: .hour, for: occurrence.date)?.end ?? occurrence.date) }
        }
        return start...max(start, end)
    }

    // A setpoint is a scheduled target, not a live power reading. Power-off clears it.
    static func heldTarget(_ occurrences: [Occurrence], side: Side, at date: Date) -> Double? {
        var target: Double?
        let ordered = occurrences.sorted {
            if $0.at != $1.at { return $0.at < $1.at }
            let clearsFirst = $0.type == "power_off" || ($0.type == "run_once" && $0.targetTempF == nil)
            let clearsSecond = $1.type == "power_off" || ($1.type == "run_once" && $1.targetTempF == nil)
            return !clearsFirst && clearsSecond
        }
        for occurrence in ordered where occurrence.side == side && occurrence.date <= date {
            if occurrence.type == "power_off" || (occurrence.type == "run_once" && occurrence.targetTempF == nil) { target = nil }
            else if ["temperature", "run_once", "power_on"].contains(occurrence.type), let temperature = occurrence.targetTempF { target = temperature }
        }
        return target
    }

    static func targetSpans(_ night: Night, side: Side, range: ClosedRange<Date>) -> [TargetSpan] {
        let boundaries = Set([range.lowerBound, range.upperBound] + night.occurrences.filter { $0.side == side && range.contains($0.date) }.map(\.date)).sorted()
        return zip(boundaries, boundaries.dropFirst()).compactMap { start, end in
            guard end > start, let target = heldTarget(night.occurrences, side: side, at: start) else { return nil }
            return TargetSpan(start: start, end: end, temperature: target)
        }
    }

    static func label(_ type: String) -> String {
        switch type {
        case "led_brightness": return "LED brightness"
        case "run_once": return "Run once"
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    func clock(_ date: Date, includeDay: Bool = false) -> String {
        let formatter = DateFormatter(); formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(includeDay ? "EEE MMM d jmm" : "jmm")
        return formatter.string(from: date)
    }

    func recurrence(_ job: Job) -> String {
        if job.oneTime {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: job.schedule) ?? ISO8601DateFormatter().date(from: job.schedule) else { return job.schedule }
            return "Once · " + clock(date, includeDay: true)
        }
        let parts = job.schedule.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 5, let minute = Int(parts[0]), (0...59).contains(minute),
              let hour = Int(parts[1]), (0...23).contains(hour), parts[2] == "*", parts[3] == "*",
              let clockDate = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute)) else { return job.schedule }
        if parts[4] == "*" { return "Daily · " + clock(clockDate) }
        let days = parts[4].split(separator: ",", omittingEmptySubsequences: false)
        guard !days.isEmpty, days.allSatisfy({ Int($0).map { (0...7).contains($0) } == true }) else { return job.schedule }
        let labels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let names = days.compactMap { Int($0).map { labels[$0 % 7] } }.joined(separator: ", ")
        return names + " · " + clock(clockDate)
    }
}

struct SystemSchedulerHealth: Decodable, Sendable {
    struct Scheduler: Decodable, Sendable {
        struct Drift: Decodable, Sendable {
            let dbScheduleCount: Int
            let schedulerJobCount: Int
            let drifted: Bool
        }
        let enabled: Bool
        let jobCount: Int
        let drift: Drift?
    }
    let scheduler: Scheduler
}
