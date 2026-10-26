import Foundation

struct AutomationActivity: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let ruleId: Int; let ruleName: String; let outcome: String; let code: String
        let start: Double; let end: Double; let count: Int; let temp: Double?; let sides: [Side]
    }
    struct Night: Decodable, Identifiable, Sendable {
        let start: Double; let entries: [Entry]
        var id: Double { start }
    }
    struct Hold: Decodable, Sendable { let side: Side; let temperature: Double; let startedAt: Double; let expiresAt: Double }
    let now: Double
    let nights: [Night]
    let holds: [Hold]
    /// Calendar subtraction preserves 6pm night boundaries across daylight-saving changes.
    static func nightStarts(count: Int, timeZone: TimeZone, now: Date = .now) -> [Double] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        guard let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now),
              let latest = evening <= now ? evening : calendar.date(byAdding: .day, value: -1, to: evening) else { return [] }
        return (0..<min(30, max(1, count))).compactMap { calendar.date(byAdding: .day, value: -$0, to: latest)?.timeIntervalSince1970 }.map { ($0 * 1000).rounded() }.sorted()
    }
}

struct AutomationZoneReplay: Decodable, Sendable {
    struct Frame: Decodable, Sendable { let tMs: Double; let zones: [Double]; let peakZone: Double? }
    let ok: Bool
    let night: AutomationBacktest.Night?
    let frames: [Frame]
}

enum AutomationDates {
    static func parse(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
    static func label(_ milliseconds: Double, timeZone: String, includeDate: Bool = false) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: timeZone)
        formatter.dateStyle = includeDate ? .medium : .none; formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }
}
