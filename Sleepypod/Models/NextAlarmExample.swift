import CryptoKit
import Foundation

struct NextAlarmExample: Decodable, Sendable {
    let synthetic: Bool
    let sourceCommit: String
    let now: Double
    let cases: [String: NextAlarmState]
    static func load() throws -> Self {
        guard let url = Bundle.main.url(forResource: "next-alarm-example", withExtension: "json") else { throw NextAlarmFailure.invalid }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
/// Ordinary Demo derives its summary from the same editable weekly rows and never saves a wake command.
struct DemoNextAlarmClient: NextAlarmClient {
    let weekly: any AlarmClient
    let timeZone: String
    func available() async throws {}
    func read(side: Side) async throws -> NextAlarmState {
        let rows = try await weekly.all(), now = Date.now, zone = TimeZone(identifier: timeZone) ?? .gmt
        let occurrences = AlarmGroup.group(rows, side: side).compactMap { group in group.nextDate(after: now, timeZone: zone).map { (group, $0) } }.sorted { $0.1 < $1.1 }
        let occurrence = occurrences.first.map { group, date in
            NextAlarmState.Occurrence(scheduleIds: group.rows.map(\.id), at: date.ISO8601Format(), originalAt: date.ISO8601Format(), time: NextAlarmState.clock(date, timeZone: timeZone),
                source: "routine", duration: Double(group.alarm.duration), wakeWindow: Double(group.alarm.wakeWindow ?? 0), alarmTemperatureF: group.alarm.alarmTemperature)
        }
        let revision = SHA256.hash(data: try JSONEncoder().encode(rows)).map { String(format: "%02x", $0) }.joined()
        return .init(apiVersion: 1, side: side, timeZone: timeZone, revision: revision, state: occurrence == nil ? "none" : "scheduled", alarm: occurrence,
            followingAt: nil, canChange: false, reason: "Demo shows the saved weekly schedule. Connect to your controller to change one wake-up.", execution: nil,
            acknowledgment: "accepted_not_physically_verified", change: nil, schedulerUpdated: nil)
    }
    func write(_ input: NextAlarmWrite) async throws -> NextAlarmState { throw NextAlarmFailure.unavailable("Connect to your controller to change one wake-up.") }
}

/// Explicit debug scenarios exercise UI recovery with source-generated examples, never live transport.
actor SyntheticNextAlarmClient: NextAlarmClient {
    let scenario: String
    private var value: NextAlarmState?
    private var writes = 0
    init(scenario: String) { self.scenario = scenario }
    func available() async throws { if scenario == "offline" { throw URLError(.notConnectedToInternet) } }
    func read(side: Side) async throws -> NextAlarmState {
        try await available()
        if value == nil {
            let fixture = try NextAlarmExample.load()
            value = fixture.cases[scenario] ?? fixture.cases["scheduled"]
        }
        guard let value else { throw NextAlarmFailure.invalid }
        return try scoped(value, side: side)
    }
    func write(_ input: NextAlarmWrite) async throws -> NextAlarmState {
        let original = try await read(side: input.side)
        guard original.revision == input.expectedRevision else { throw NextAlarmFailure.conflict }
        writes += 1
        let fixture = try NextAlarmExample.load()
        if scenario == "conflict", writes == 1 { value = fixture.cases["invalidated"]; throw NextAlarmFailure.conflict }
        let name = input.action == "skip" ? "skipped" : input.action == "restore" ? "restored" : "changed"
        guard let example = fixture.cases[name],
              var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(example)) as? [String: Any] else { throw NextAlarmFailure.invalid }
        fields["revision"] = SHA256.hash(data: Data("synthetic-\(writes)-\(name)".utf8)).map { String(format: "%02x", $0) }.joined()
        fields["schedulerUpdated"] = scenario != "pending"
        if input.action == "time", let time = input.time, let wakeDate = original.alarm.flatMap({ NextAlarmState.instant($0.originalAt) }),
           let minutes = AlarmDraft.clockMinutes(time), var alarm = fields["alarm"] as? [String: Any], var change = fields["change"] as? [String: Any] {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: original.timeZone) ?? .gmt
            guard let date = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: wakeDate) else { throw NextAlarmFailure.invalid }
            alarm["time"] = time; alarm["at"] = date.ISO8601Format(); change["at"] = date.ISO8601Format()
            fields["alarm"] = alarm; fields["change"] = change
        }
        value = try JSONDecoder().decode(NextAlarmState.self, from: JSONSerialization.data(withJSONObject: fields))
        if scenario == "lost-save", writes == 1 { throw URLError(.networkConnectionLost) }
        guard let value else { throw NextAlarmFailure.invalid }
        return try scoped(value, side: input.side)
    }
    private func scoped(_ source: NextAlarmState, side: Side) throws -> NextAlarmState {
        guard var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any] else { throw NextAlarmFailure.invalid }
        fields["side"] = side.rawValue
        return try JSONDecoder().decode(NextAlarmState.self, from: JSONSerialization.data(withJSONObject: fields))
    }
}
