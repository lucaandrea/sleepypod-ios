import Foundation

struct AlarmPreview: Decodable, Sendable {
    struct Occurrence: Decodable, Sendable {
        var at: String
        var time: String
        var scheduleDay: String?
        var source: String
    }
    var side: BedSide
    var timeZone: String
    var state: String
    var alarm: Occurrence?
    var expiresAt: String?
    var overrideRevision: String?

    var title: String {
        switch state {
        case "away": "Away mode"
        case "paused": "Routine alarm paused"
        default: alarm.map { format($0.at, pattern: "h:mm a") } ?? "No alarm scheduled"
        }
    }
    var badge: String {
        if alarm?.source == "override" { return "Changed once" }
        switch state {
        case "scheduled": return "Routine"
        case "paused": return "Paused"
        case "away": return "Away"
        default: return "Not set"
        }
    }
    var detail: String {
        if state == "away" { return "Alarms are paused for this side while Away mode is on." }
        if state == "paused", let expiresAt { return "Until \(format(expiresAt, pattern: "EEE, MMM d · h:mm a")) · \(timeZone)" }
        if let alarm { return "\(format(alarm.at, pattern: "EEE, MMM d")) · \(timeZone)" }
        return "Set a vibration alarm in Routines."
    }
    func format(_ timestamp: String, pattern: String) -> String {
        guard let date = Self.date(timestamp) else { return "Unknown time" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZone)
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
    static func date(_ timestamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestamp) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp)
    }
}

struct AlarmChange: Encodable, Sendable {
    enum Action: String, Encodable, Sendable { case time, disable, restore }
    var side: BedSide
    var action: Action
    var time: String?
    var expectedAt: String?
    var expectedExpiresAt: String?
    var expectedRevision: String?

    init(preview: AlarmPreview, action: Action, time: String? = nil) {
        side = preview.side; self.action = action
        self.time = action == .time ? time : nil
        expectedAt = action == .restore ? nil : preview.alarm?.at
        expectedExpiresAt = action == .restore ? preview.expiresAt : nil
        expectedRevision = action == .restore ? preview.overrideRevision : nil
    }
}

// A neutral UTC date represents the picker’s clock fields; the server resolves the displayed alarm date and timezone.
enum AlarmClock {
    static func date(_ time: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "2001-01-01 \(time)") ?? Date(timeIntervalSinceReferenceDate: 0)
    }
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .gmt; formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
