import Foundation

struct EpisodeDetail: Decodable, Sendable {
    struct Interval: Decodable, Sendable { var start: Double; var end: Double }
    struct Sample: Decodable, Sendable {
        var at: Double
        var heartRate: Double?
        var hrv: Double?
        var respiratoryRate: Double?
        var present: Bool?
    }
    struct Point: Decodable, Sendable { var seconds: Double; var value: Double }
    struct Plot: Decodable, Sendable, Identifiable {
        var key: String
        var title: String
        var unit: String
        var segments: [[Point]]
        var count: Int
        var average: Double?
        var minimum: Double?
        var maximum: Double?
        var id: String { key }
    }
    var side: String
    var timeZone: String
    var episode: SleepAnalytics.Night
    var durationSeconds: Double
    var presenceKnown: Bool
    var intervals: [Interval]
    var samples: [Sample]
    var plots: [Plot]
    var notes: [String]
    static func number(_ value: Double?) -> String {
        value?.formatted(.number.precision(.fractionLength(0...1))) ?? "—"
    }
    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static func clock(_ date: Date, timeZone: String, format: String = "MMM d HH:mm") -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZone) ?? .gmt; formatter.dateFormat = format
        return formatter.string(from: date)
    }
    func clock(_ seconds: Double) -> String {
        guard let start = Self.date(episode.startedAt) else { return "—" }
        return Self.clock(start.addingTimeInterval(seconds), timeZone: timeZone)
    }
}

struct SleepDemo: Decodable {
    struct Record: Decodable {
        var id: Int
        var side: String
        var entered_bed_at: Double
        var left_bed_at: Double
        var sleep_period_seconds: Double
        var times_exited_bed: Int
        var present_intervals: String
        var not_present_intervals: String
    }
    struct Vital: Decodable {
        var timestamp: Double
        var heart_rate: Double?
        var hrv: Double?
        var breathing_rate: Double?
    }
    var anchor: Double
    var records: [Record]
    var vitals: [Vital]
    var analytics: SleepAnalytics
    var ranges: [String: SleepAnalytics]
    var details: [String: EpisodeDetail]
    var coaching: [String: Coaching]
    static let shared: SleepDemo? = {
        guard let url = Bundle.main.url(forResource: "sleep-demo", withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SleepDemo.self, from: data)
    }()
}
