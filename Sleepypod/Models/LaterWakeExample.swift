import Foundation

/// Explicit simulator examples translate Core's generated packet together. They
/// have no network transport, durable storage or operating-system alarm client.
enum LaterWakeExample {
    @MainActor private static var backups: [String: BackupAlarmCoordinator] = [:]
    @MainActor private static var clients: [String: SyntheticLaterWakeClient] = [:]
    @MainActor static func client(scenario: String, side: Side) -> SyntheticLaterWakeClient {
        let key = scenario + side.rawValue
        if let client = clients[key] { return client }
        let client = SyntheticLaterWakeClient(scenario: scenario); clients[key] = client
        return client
    }
    static func data() throws -> Data {
        guard let path = Bundle.main.url(forResource: "later-wake-example", withExtension: "json") else { throw NextAlarmFailure.invalid }
        return try Data(contentsOf: path)
    }
    @MainActor static func companionIfRequested() -> LaterWakeCompanion? {
        guard APIBackend.current.isDemo, DebugRoute.nextAlarmScenario.hasPrefix("later-") else { return nil }
        let scenario = DebugRoute.nextAlarmScenario, owner = String(repeating: "d", count: 64)
        if let backup = backups[scenario] { return LaterWakeCompanion(backup: backup, owner: { owner }, isPractice: true) }
        let storage = LaterWakeMemoryBackup()
        storage.refuse = scenario == "later-phone-failure"
        storage.disappearAfterConfirmation = scenario == "later-phone-missing"
        let backup = BackupAlarmCoordinator(client: storage, owner: { owner }, read: { storage.record }, persist: { storage.record = $0 })
        backups[scenario] = backup
        return LaterWakeCompanion(backup: backup, owner: { owner }, isPractice: true)
    }
}

actor SyntheticLaterWakeClient: LaterWakeClient {
    let scenario: String
    private var current: NextAlarmState?
    private var source: [String: Any] = [:]
    private var side: Side = .left
    private var previewed = false
    private var wrote = false
    init(scenario: String) { self.scenario = scenario }
    func available() async throws {}
    func laterAvailable() async throws {}
    func read(side: Side) async throws -> NextAlarmState {
        if current == nil { try prepare(side: side) }
        if scenario == "later-offline", previewed { throw URLError(.notConnectedToInternet) }
        if scenario == "later-changed", previewed, !wrote {
            var fields = try object(current as Any)
            fields["revision"] = String(repeating: "c", count: 64)
            current = try decode(fields)
        }
        guard let current else { throw NextAlarmFailure.invalid }
        return current
    }
    func previewLater(_ input: LaterWakeRequest) async throws -> LaterWakePacket {
        if scenario == "later-preview-rejected" { throw NextAlarmFailure.unavailable("The controller could not preview this wake. Refresh the saved alarm and try again.") }
        guard let current, input.expectedRevision == current.revision,
              let original = current.alarm.flatMap({ NextAlarmState.instant($0.at) }),
              let minutes = AlarmDraft.clockMinutes(input.time) else { throw NextAlarmFailure.conflict }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        guard let proposed = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: original), proposed > original else {
            throw NextAlarmFailure.unavailable("Choose a later time on the same wake date.")
        }
        var fields = try dictionary(source["preview"]), proposal = try dictionary(fields["proposed"])
        guard let old = (proposal["at"] as? String).flatMap(NextAlarmState.instant) else { throw NextAlarmFailure.invalid }
        let delta = proposed.timeIntervalSince(old)
        for key in ["at", "warmingStartsAt", "earliestVibrationAt", "warmingEndsAt", "changeExpiresAt"] {
            guard let date = (proposal[key] as? String).flatMap(NextAlarmState.instant) else { throw NextAlarmFailure.invalid }
            proposal[key] = date.addingTimeInterval(delta).ISO8601Format()
        }
        proposal["time"] = input.time
        fields["proposed"] = proposal
        fields["request"] = ["side": side.rawValue, "expectedRevision": input.expectedRevision, "expectedAt": input.expectedAt, "action": "time", "time": input.time]
        let now = Date.now
        fields["generatedAt"] = now.ISO8601Format()
        fields["expiresAt"] = now.addingTimeInterval(scenario == "later-expired" ? 3 : 90).ISO8601Format()
        previewed = true
        return try LaterWakePacket(data: JSONSerialization.data(withJSONObject: fields), input: input, now: now)
    }
    func applyLater(_ packet: LaterWakePacket) async throws -> NextAlarmState {
        _ = try packet.application(now: .now)
        guard current?.revision == packet.input.expectedRevision else { throw NextAlarmFailure.conflict }
        let proposal = packet.preview.proposed
        var fields = try dictionary(source["saved"]), alarm = try dictionary(fields["alarm"]), change = try dictionary(fields["change"])
        alarm["at"] = proposal.at; alarm["time"] = proposal.time
        change["at"] = proposal.at; change["expiresAt"] = proposal.changeExpiresAt
        fields["alarm"] = alarm; fields["change"] = change
        fields["warming"] = ["startsAt": proposal.warmingStartsAt, "endsAt": proposal.warmingEndsAt,
            "earliestVibrationAt": proposal.earliestVibrationAt, "targetF": proposal.targetF]
        fields["schedulerUpdated"] = scenario != "later-pending"
        let saved: NextAlarmState = try decode(fields)
        try packet.preview.validateSaved(saved)
        current = saved; wrote = true
        if scenario == "later-lost" { throw URLError(.networkConnectionLost) }
        return saved
    }
    func write(_ input: NextAlarmWrite) async throws -> NextAlarmState {
        guard input.action == "restore", input.expectedRevision == current?.revision else { throw NextAlarmFailure.invalid }
        var fields = try dictionary(source["restored"])
        fields["schedulerUpdated"] = true
        current = try decode(fields)
        guard let current else { throw NextAlarmFailure.invalid }
        return current
    }
    private func prepare(side: Side) throws {
        let root = try dictionary(JSONSerialization.jsonObject(with: LaterWakeExample.data()))
        let cases = try dictionary(root["cases"]), original = try dictionary(cases["ordinary"])
        let before = try dictionary(original["before"]), alarm = try dictionary(before["alarm"])
        guard let originalAt = (alarm["at"] as? String).flatMap(NextAlarmState.instant) else { throw NextAlarmFailure.invalid }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let tomorrow = calendar.startOfDay(for: .now).addingTimeInterval(86_400 + 7 * 3600)
        source = try dictionary(translate(original, by: tomorrow.timeIntervalSince(originalAt), side: side))
        self.side = side; current = try decode(dictionary(source["before"]))
    }
    private func translate(_ value: Any, by interval: Double, side: Side) -> Any {
        if let fields = value as? [String: Any] {
            return fields.mapValues { translate($0, by: interval, side: side) }.merging(fields["side"] == nil ? [:] : ["side": side.rawValue]) { _, new in new }
        }
        if let array = value as? [Any] { return array.map { translate($0, by: interval, side: side) } }
        if let text = value as? String, let date = NextAlarmState.instant(text) { return date.addingTimeInterval(interval).ISO8601Format() }
        return value
    }
    private func dictionary(_ value: Any?) throws -> [String: Any] {
        guard let value = value as? [String: Any] else { throw NextAlarmFailure.invalid }; return value
    }
    private func object(_ value: Any) throws -> [String: Any] {
        guard let value = value as? NextAlarmState else { throw NextAlarmFailure.invalid }
        return try dictionary(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)))
    }
    private func decode(_ value: [String: Any]) throws -> NextAlarmState {
        try JSONDecoder().decode(NextAlarmState.self, from: JSONSerialization.data(withJSONObject: value))
    }
}

@MainActor private final class LaterWakeMemoryBackup: BackupAlarmClient {
    var record: BackupAlarmRecord?
    var refuse = false
    var disappearAfterConfirmation = false
    private var confirmedOnce = false
    private var values: [BackupSystemAlarm] = []
    func requestAccess() async throws -> Bool { !refuse }
    func alarms() throws -> [BackupSystemAlarm] {
        if disappearAfterConfirmation, confirmedOnce { values = [] }
        if !values.isEmpty { confirmedOnce = true }
        return values
    }
    func schedule(id: UUID, at: Date) async throws { values.append(.init(id: id, at: at, state: "scheduled")) }
    func cancel(id: UUID) throws { values.removeAll { $0.id == id } }
}
