import Foundation

/// Retained physical-zone evidence. An observation does not identify the sleeper or prove an effect.
struct NightExplanation: Codable, Sendable {
    let apiVersion: Int
    let generatedAt: Double
    let side: Side
    let wakeDate: String
    let timeZone: String
    let start: Double
    let end: Double
    let observedThrough: Double
    let attribution: String
    let events: [Event]
    let eventsTruncated: Bool
    let thermal: [Thermal]
    let room: [Room]
    let roomSampleIntervalMs: Int
    let roomTruncated: Bool
    let sources: [Source]

    enum SourceKey: String, Codable, Sendable, CaseIterable {
        case applications, decisions, rules, thermal, room
        var title: String {
            switch self {
            case .applications: "Controller requests"
            case .decisions: "Personal Autopilot"
            case .rules: "Automation rules"
            case .thermal: "Pod temperatures"
            case .room: "Room conditions"
            }
        }
    }
    enum Kind: String, Codable, Sendable {
        case acknowledged, unconfirmed, preview, withheld, feedback, configuration
        case ruleOutput = "rule_output"
        var title: String {
            switch self {
            case .acknowledged: "Acknowledged"
            case .unconfirmed: "Unconfirmed"
            case .preview: "Proposal only"
            case .withheld: "Held back"
            case .feedback: "Feedback"
            case .configuration: "Configuration"
            case .ruleOutput: "Rule log"
            }
        }
    }
    struct Event: Codable, Sendable, Identifiable {
        let id: String
        let source: SourceKey
        let at: Double
        let through: Double
        let count: Int
        let scope: String
        let kind: Kind
        let title: String
        let detail: String
        let targetF: Double?
        let reportedF: Double?
        let owner: String?
        let evidence: String
    }
    struct Thermal: Codable, Sendable, Identifiable {
        let id: Int
        let at: Double
        let powered: Bool
        let targetF: Double?
        let reportedF: Double?
    }
    struct Room: Codable, Sendable, Identifiable {
        let id: Int
        let sourceId: String
        let revision: Int
        let label: String
        let metric: String
        let value: Double?
        let unit: String
        let receivedAt: Double
        let observedAt: Double
        let measuredAt: Double?
        let timeBasis: String
    }
    struct Source: Codable, Sendable, Identifiable {
        let key: SourceKey
        let status: String
        let rowsRead: Int
        let discarded: Int
        let truncated: Bool
        let note: String
        var id: SourceKey { key }
    }
    func current(at now: Date) -> Bool {
        let timestamp = now.timeIntervalSince1970 * 1000
        return generatedAt <= timestamp && timestamp - generatedAt < 300_000
    }
    /// Reject malformed clocks, attribution, ranges and source identities before presentation.
    func validate() throws {
        guard apiVersion == 1, attribution == "physical_zone_only", TimeZone(identifier: timeZone) != nil,
              Self.validDate(wakeDate), [generatedAt, start, end, observedThrough].allSatisfy(Self.validClock),
              start < end, end - start <= 26 * 3_600_000, observedThrough >= start,
              observedThrough <= end, observedThrough <= generatedAt, roomSampleIntervalMs == 300_000,
              sources.count == 5, Set(sources.map(\.key)) == Set(SourceKey.allCases),
              events.count <= 600, thermal.count <= 3000, room.count <= 2000 else { throw invalid }
        for source in sources {
            guard ["read", "empty", "partial", "unavailable"].contains(source.status), source.rowsRead >= 0,
                  source.discarded >= 0, source.note.count <= 1000 else { throw invalid }
        }
        guard Set(events.map(\.id)).count == events.count, Set(thermal.map(\.id)).count == thermal.count,
              Set(room.map(\.id)).count == room.count else { throw invalid }
        for event in events {
            guard !event.id.isEmpty, event.id.count <= 200, ["applications", "decisions", "rules"].contains(event.source.rawValue),
                  validObservation(event.at), Self.validClock(event.through), event.through >= event.at, event.through <= observedThrough,
                  event.count > 0, event.scope == side.rawValue || event.scope == "unassigned", !event.title.isEmpty,
                  event.title.count <= 160, event.detail.count <= 2400, Self.temperature(event.targetF, in: 55...110),
                  Self.temperature(event.reportedF, in: 32...130), [nil, "manual", "run-once", "autopilot", "schedule"].contains(event.owner),
                  ["controller_receipt", "policy_evaluation", "rule_evaluation"].contains(event.evidence) else { throw invalid }
        }
        for sample in thermal {
            guard sample.id > 0, validObservation(sample.at), Self.temperature(sample.targetF, in: 55...110),
                  Self.temperature(sample.reportedF, in: 32...130) else { throw invalid }
        }
        for sample in room {
            guard sample.id > 0, !sample.sourceId.isEmpty, sample.sourceId.count <= 200, sample.revision > 0,
                  sample.label.count <= 180, ["temperature", "humidity", "pm25", "co2", "airQuality"].contains(sample.metric),
                  sample.value?.isFinite != false, sample.unit.count <= 20, validObservation(sample.receivedAt),
                  Self.validClock(sample.observedAt), sample.observedAt <= sample.receivedAt,
                  sample.measuredAt.map({ Self.validClock($0) && $0 <= sample.observedAt }) != false,
                  ["measurement", "device_read", "integration_report", "cached"].contains(sample.timeBasis) else { throw invalid }
        }
    }
    private var invalid: APIError { .invalidResponse(statusCode: 0) }
    private func validObservation(_ timestamp: Double) -> Bool {
        Self.validClock(timestamp) && timestamp >= start && timestamp < end && timestamp <= observedThrough
    }
    private static func validClock(_ timestamp: Double) -> Bool {
        timestamp.isFinite && timestamp >= 0 && timestamp <= 8_640_000_000_000_000 && timestamp.rounded(.down) == timestamp
    }
    private static func temperature(_ value: Double?, in range: ClosedRange<Double>) -> Bool {
        value.map { $0.isFinite && range.contains($0) } ?? true
    }
    static func dateKey(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    private static func validDate(_ value: String) -> Bool {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return value.count == 10 && formatter.date(from: value).map { formatter.string(from: $0) == value } == true
    }
}
