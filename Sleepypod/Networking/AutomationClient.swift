import Foundation

protocol AutomationClient: Sendable {
    func rules() async throws -> [AutomationRule]
    func globalEnabled() async throws -> Bool
    func setGlobalEnabled(_ enabled: Bool) async throws -> Bool
    func create(_ definition: AutomationDefinition) async throws -> AutomationRule
    func update(id: Int, definition: AutomationDefinition) async throws -> AutomationRule
    func mode(id: Int, mode: AutomationMode) async throws -> AutomationRule
    func delete(id: Int) async throws
    func diagnostics() async throws -> AutomationDiagnostics
    func activity(nightStarts: [Double]) async throws -> AutomationActivity
    func zones(side: Side, night: Int?) async throws -> AutomationZoneReplay
    func tonight() async throws -> AutomationTonight
    func nights(side: Side) async throws -> [AutomationNight]
    func backtest(_ definition: AutomationDefinition, side: Side, night: Int?) async throws -> AutomationBacktest
}

struct CoreAutomationClient: AutomationClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient {
        get throws { guard let transport else { throw APIError.noBaseURL }; return transport }
    }
    private struct Switch: Codable, Sendable { let enabled: Bool }
    func rules() async throws -> [AutomationRule] { try await client.get("automations") }
    func globalEnabled() async throws -> Bool {
        let result: Switch = try await client.get("automations/kill-switch"); return result.enabled
    }
    func setGlobalEnabled(_ enabled: Bool) async throws -> Bool {
        try await client.post("automations/kill-switch", body: Switch(enabled: enabled), returning: Switch.self).enabled
    }
    func create(_ definition: AutomationDefinition) async throws -> AutomationRule {
        try await client.post("automations", body: definition, returning: AutomationRule.self)
    }
    func update(id: Int, definition: AutomationDefinition) async throws -> AutomationRule {
        try await client.patch("automations", body: AutomationPatch(id: id, definition: definition), returning: AutomationRule.self)
    }
    func mode(id: Int, mode: AutomationMode) async throws -> AutomationRule {
        struct Request: Encodable, Sendable { let id: Int; let enabled: Bool; let dryRun: Bool }
        return try await client.patch("automations", body: Request(id: id, enabled: mode != .off, dryRun: mode != .active), returning: AutomationRule.self)
    }
    func delete(id: Int) async throws { try await client.delete("automations", query: ["id": String(id)]) }
    func activity(nightStarts: [Double]) async throws -> AutomationActivity {
        struct Request: Encodable, Sendable { let nightStarts: [Double] }
        return try await client.post("automations/activity", body: Request(nightStarts: nightStarts), returning: AutomationActivity.self)
    }
    func zones(side: Side, night: Int?) async throws -> AutomationZoneReplay {
        var query = ["side": side.rawValue, "maxFrames": "300"]
        if let night { query["sleepRecordId"] = String(night) }
        return try await client.get("automations/cap-zone-replay", query: query)
    }
    func diagnostics() async throws -> AutomationDiagnostics { try await client.get("automations/diagnostics", query: ["hours": "3"]) }
    func tonight() async throws -> AutomationTonight { try await client.get("automations/tonight") }
    func nights(side: Side) async throws -> [AutomationNight] { try await client.get("automations/nights", query: ["side": side.rawValue, "limit": "30"]) }
    func backtest(_ definition: AutomationDefinition, side: Side, night: Int?) async throws -> AutomationBacktest {
        try await client.post("automations/backtest", body: AutomationBacktestRequest(side: side, sleepRecordId: night, rule: .init(definition: definition)), returning: AutomationBacktest.self)
    }
}

actor DemoAutomationClient: AutomationClient {
    private var enabled = false
    private var nextID = 3
    private var values: [AutomationRule] = {
        var evening = AutomationDefinition(name: "Evening room warmth", side: .left, cooldownMin: 30,
            conditions: .all([.time(start: "21:00", end: "07:00"), .compare(operation: ">", left: .window(function: "avg", signal: "ambient.temperature", minutes: 10), right: .literal(76))]),
            actions: [.init(kind: .setTemperature, temp: .binary(operation: "-", left: .signal("left.currentTemperature"), right: .literal(2)), clamp: .init(min: 65, max: 85), durationSec: 1800)])
        evening.priority = 10
        let missing = AutomationDefinition(name: "Movement notice", side: .right,
            conditions: .compare(operation: ">", left: .signal("right.movement"), right: .literal(80)),
            actions: [.init(kind: .notify, message: "Movement is above your threshold")])
        return [AutomationRule(id: 1, definition: evening, createdAt: "2026-10-25T18:00:00Z", updatedAt: "2026-10-25T18:00:00Z"),
                AutomationRule(id: 2, definition: missing, createdAt: "2026-10-25T18:00:00Z", updatedAt: "2026-10-25T18:00:00Z")]
    }()
    func rules() -> [AutomationRule] { values.sorted { $0.definition.priority != $1.definition.priority ? $0.definition.priority > $1.definition.priority : $0.id < $1.id } }
    func globalEnabled() -> Bool { enabled }
    func setGlobalEnabled(_ enabled: Bool) -> Bool { self.enabled = enabled; return enabled }
    func create(_ definition: AutomationDefinition) throws -> AutomationRule {
        if let validation = definition.validation { throw APIError.serverError(message: validation) }
        let now = Date.now.ISO8601Format(); let rule = AutomationRule(id: nextID, definition: definition, createdAt: now, updatedAt: now)
        nextID += 1; values.append(rule); return rule
    }
    func update(id: Int, definition: AutomationDefinition) throws -> AutomationRule {
        if let validation = definition.validation { throw APIError.serverError(message: validation) }
        guard let index = values.firstIndex(where: { $0.id == id }) else { throw APIError.serverError(message: "This automation was deleted.") }
        let rule = AutomationRule(id: id, definition: definition, createdAt: values[index].createdAt, updatedAt: Date.now.ISO8601Format())
        values[index] = rule; return rule
    }
    func mode(id: Int, mode: AutomationMode) throws -> AutomationRule {
        guard var definition = values.first(where: { $0.id == id })?.definition else { throw APIError.serverError(message: "This automation was deleted.") }
        definition.mode = mode; return try update(id: id, definition: definition)
    }
    func delete(id: Int) { values.removeAll { $0.id == id } }
    func activity(nightStarts: [Double]) -> AutomationActivity {
        .init(now: Date.now.timeIntervalSince1970 * 1000, nights: nightStarts.reversed().map { .init(start: $0, entries: []) }, holds: [])
    }
    func zones(side: Side, night: Int?) -> AutomationZoneReplay { .init(ok: false, night: nil, frames: []) }
    func diagnostics() -> AutomationDiagnostics {
        let now = Date.now
        return .init(now: now.ISO8601Format(), since: now.addingTimeInterval(-10800).ISO8601Format(), startOfDay: Calendar.current.startOfDay(for: now).ISO8601Format(), globalEnabled: enabled,
            rules: rules().map { rule in
                .init(rule: rule, runs: [.init(t: now.addingTimeInterval(-90).ISO8601Format(), outcome: "skipped", reason: rule.id == 2 ? "condition-unknown" : "condition-false", sent: false)],
                      signals: rule.id == 2 ? ["right.movement": nil] : ["ambient.temperature": 74])
            })
    }
    func tonight() -> AutomationTonight {
        let state = AutomationTonight.State(control: nil, hold: nil, runOnceUntil: nil, lastAutopilot: nil)
        return .init(now: Date.now.timeIntervalSince1970 * 1000, sides: .init(left: state, right: state))
    }
    func nights(side: Side) -> [AutomationNight] { [] }
    func backtest(_ definition: AutomationDefinition, side: Side, night: Int?) -> AutomationBacktest {
        if DebugRoute.automationReplayFixture,
           let url = Bundle.main.url(forResource: "automation-backtest-fixture", withExtension: "json"),
           let data = try? Data(contentsOf: url), let fixture = try? JSONDecoder().decode(AutomationBacktest.self, from: data) { return fixture }
        return .init(ok: false, message: "Demo has no recorded controller nights. Connect to your Pod to replay this draft against recorded signals.", night: nil, result: nil)
    }
}
