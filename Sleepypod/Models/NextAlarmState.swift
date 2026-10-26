import Foundation

enum NextAlarmFailure: LocalizedError, Equatable {
    case invalid, conflict, unavailable(String)
    var errorDescription: String? {
        switch self {
        case .invalid: "The saved alarm could not be verified. Refresh it before making a change."
        case .conflict: "This alarm changed. Your time draft is kept. Refresh and review the saved alarm before trying again."
        case .unavailable(let message): message
        }
    }
}
struct NextAlarmState: Codable, Equatable, Sendable {
    struct Occurrence: Codable, Equatable, Sendable {
        let scheduleIds: [Int]
        let at: String
        let originalAt: String
        let time: String
        let source: String
        let duration: Double
        let wakeWindow: Double
        let alarmTemperatureF: Double
    }
    struct Change: Codable, Equatable, Sendable {
        let revision: String
        let status: String
        let originalAt: String
        let at: String?
        let expiresAt: String
    }
    let apiVersion: Int
    let side: Side
    let timeZone: String
    let revision: String
    let state: String
    let alarm: Occurrence?
    let followingAt: String?
    let canChange: Bool
    let reason: String
    let execution: String?
    let acknowledgment: String
    let change: Change?
    let schedulerUpdated: Bool?
    /// Keep timestamp strings untouched for the server's exact occurrence preconditions.
    func validate(side: Side, write: Bool = false) throws {
        guard apiVersion == 1, self.side == side, TimeZone(identifier: timeZone) != nil,
              Self.validRevision(revision), ["scheduled", "skipped", "none", "away"].contains(state),
              acknowledgment == "accepted_not_physically_verified", !write || schedulerUpdated != nil,
              execution.map({ ["attempting", "acknowledged", "unknown"].contains($0) }) ?? true else { throw NextAlarmFailure.invalid }
        guard state != "none" || alarm == nil,
              !canChange || (execution == nil && ["scheduled", "skipped"].contains(state)) else { throw NextAlarmFailure.invalid }
        if let alarm {
            guard !alarm.scheduleIds.isEmpty, Set(alarm.scheduleIds).count == alarm.scheduleIds.count, alarm.scheduleIds.allSatisfy({ $0 > 0 }),
                  let at = Self.instant(alarm.at), Self.instant(alarm.originalAt) != nil, Self.validClock(alarm.time),
                  Self.clock(at, timeZone: timeZone) == alarm.time, ["routine", "override"].contains(alarm.source),
                  alarm.duration.isFinite, alarm.duration >= 0, alarm.wakeWindow.isFinite, alarm.wakeWindow >= 0, alarm.alarmTemperatureF.isFinite else { throw NextAlarmFailure.invalid }
        } else if ["scheduled", "skipped"].contains(state) || canChange { throw NextAlarmFailure.invalid }
        if let followingAt, Self.instant(followingAt) == nil { throw NextAlarmFailure.invalid }
        if let change {
            guard UUID(uuidString: change.revision) != nil, ["active", "expired", "invalidated"].contains(change.status),
                  Self.instant(change.originalAt) != nil, Self.instant(change.expiresAt) != nil,
                  change.at.map({ Self.instant($0) != nil }) ?? true else { throw NextAlarmFailure.invalid }
        }
    }
    static func validRevision(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    static func validClock(_ value: String) -> Bool { value.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil }
    static func instant(_ value: String) -> Date? {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func clock(_ date: Date, timeZone: String) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: timeZone) ?? .gmt
        return String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
    }
    func label(_ value: String) -> String {
        guard let date = Self.instant(value) else { return "Unavailable" }
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: timeZone); formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
struct NextAlarmWrite: Codable, Equatable, Sendable {
    let side: Side
    let action: String
    let expectedRevision: String
    let expectedAt: String?
    let expectedExpiresAt: String?
    let time: String?
    init(base: NextAlarmState, action: String, time: String? = nil) throws {
        try base.validate(side: base.side)
        guard ["skip", "time", "restore"].contains(action) else { throw NextAlarmFailure.invalid }
        if action == "restore" { guard base.change != nil, time == nil else { throw NextAlarmFailure.invalid } }
        else {
            guard base.canChange, base.alarm != nil else { throw NextAlarmFailure.conflict }
            guard (action == "time" && time.map(NextAlarmState.validClock) == true) || (action == "skip" && time == nil) else { throw NextAlarmFailure.invalid }
        }
        side = base.side; self.action = action; expectedRevision = base.revision
        expectedAt = action == "restore" ? nil : base.alarm?.at
        expectedExpiresAt = action == "restore" ? base.change?.expiresAt : nil; self.time = time
    }
}
