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
    /// A fixed night scale keeps identical loads the same color while scrubbing.
    var scale: Double { max(0.01, frames.flatMap(\.zones).filter(\.isFinite).max() ?? 0.01) }
    static func liveZones(_ variance: [Float]) -> [Double] {
        (0..<3).map { zone in
            let pair = [zone * 2, zone * 2 + 1].compactMap { variance.indices.contains($0) && variance[$0].isFinite ? Double(variance[$0]) : nil }
            return pair.max() ?? .nan
        }
    }
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

enum AutomationActivityFilter: String, CaseIterable, Identifiable {
    case all = "All", wouldFire = "Would fire", fired = "Fired", skipped = "Skipped", missing = "Missing", errors = "Errors"
    var id: Self { self }
    func matches(_ entry: AutomationActivity.Entry) -> Bool {
        switch self {
        case .all: true
        case .wouldFire: entry.outcome == "dry_run"
        case .fired: entry.outcome == "fired" || entry.outcome == "clamped"
        case .skipped: entry.outcome == "skipped"
        case .missing: entry.code == "signal-unavailable" || entry.code.contains("unknown") || entry.code.contains("missing")
        case .errors: entry.outcome == "error"
        }
    }
}
