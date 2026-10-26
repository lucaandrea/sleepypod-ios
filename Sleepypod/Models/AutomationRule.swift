import Foundation

struct AutomationDefinition: Codable, Equatable, Sendable {
    var name = "New automation"
    var enabled = true
    var side: Side? = .left
    var priority = 0
    var dryRun = true
    var cooldownMin: Int?
    var trigger = AutomationTrigger()
    var conditions = AutomationCondition.all([])
    var actions: [AutomationAction] = [.init(kind: .notify, message: "Automation matched")]
    enum CodingKeys: CodingKey { case name, enabled, side, priority, dryRun, cooldownMin, trigger, conditions, actions }
    // Nullable fields must be explicit: omission in a PATCH would retain the old side or cooldown.
    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(name, forKey: .name); try fields.encode(enabled, forKey: .enabled)
        try fields.encode(side, forKey: .side); try fields.encode(priority, forKey: .priority)
        try fields.encode(dryRun, forKey: .dryRun); try fields.encode(cooldownMin, forKey: .cooldownMin)
        try fields.encode(trigger, forKey: .trigger); try fields.encode(conditions, forKey: .conditions)
        try fields.encode(actions, forKey: .actions)
    }
    var validation: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 120 { return "Give this automation a name of 1–120 characters." }
        if !(0...1000).contains(priority) { return "Priority must be 0–1000." }
        if let cooldownMin, !(0...1440).contains(cooldownMin) { return "Cooldown must be 0–1440 minutes." }
        if !trigger.valid { return "Check the trigger signal, time or interval." }
        if !conditions.valid() { return "Check the conditions, times and expression values." }
        if !(1...10).contains(actions.count) || !actions.allSatisfy(\.valid) { return "Add 1–10 valid actions. Temperature limits must be whole degrees between 55°F and 110°F." }
        if conditions.nodeCount + actions.reduce(0, { $0 + ($1.temp?.nodeCount ?? 0) }) > 400 { return "This automation is too complex (maximum 400 expression nodes)." }
        return nil
    }
    var mode: AutomationMode {
        get { !enabled ? .off : dryRun ? .dryRun : .active }
        set { enabled = newValue != .off; dryRun = newValue != .active }
    }
}

enum AutomationMode: String, CaseIterable, Identifiable, Sendable {
    case off = "Off", dryRun = "Dry run", active = "Active"
    var id: String { rawValue }
}

struct AutomationRule: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    var definition: AutomationDefinition
    let createdAt: String
    let updatedAt: String
    private enum CodingKeys: CodingKey { case id, createdAt, updatedAt }
    init(id: Int, definition: AutomationDefinition, createdAt: String, updatedAt: String) {
        self.id = id; self.definition = definition; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(Int.self, forKey: .id)
        createdAt = try fields.decode(String.self, forKey: .createdAt)
        updatedAt = try fields.decode(String.self, forKey: .updatedAt)
        definition = try AutomationDefinition(from: decoder)
    }
    func encode(to encoder: Encoder) throws {
        try definition.encode(to: encoder)
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(id, forKey: .id); try fields.encode(createdAt, forKey: .createdAt); try fields.encode(updatedAt, forKey: .updatedAt)
    }
}

struct AutomationPatch: Encodable, Sendable {
    let id: Int
    let definition: AutomationDefinition
    enum CodingKeys: CodingKey { case id }
    func encode(to encoder: Encoder) throws {
        try definition.encode(to: encoder)
        var fields = encoder.container(keyedBy: CodingKeys.self); try fields.encode(id, forKey: .id)
    }
}

struct AutomationDiagnostics: Decodable, Sendable {
    struct Run: Codable, Sendable {
        let t: String
        let outcome: String
        let reason: String?
        let sent: Bool
        var label: String { reason == "condition-unknown" ? "Missing signal" : sent ? "Sent to bed" : outcome == "dry_run" ? "Would fire" : reason?.replacingOccurrences(of: "-", with: " ") ?? outcome }
    }
    struct Rule: Decodable, Identifiable, Sendable {
        let rule: AutomationRule
        let runs: [Run]
        let signals: [String: Double?]
        var id: Int { rule.id }
        enum CodingKeys: CodingKey { case runs, signals }
        init(from decoder: Decoder) throws {
            rule = try AutomationRule(from: decoder)
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            runs = try fields.decode([Run].self, forKey: .runs); signals = try fields.decode([String: Double?].self, forKey: .signals)
        }
        init(rule: AutomationRule, runs: [Run], signals: [String: Double?]) { self.rule = rule; self.runs = runs; self.signals = signals }
    }
    let now: String
    let since: String
    let startOfDay: String
    let globalEnabled: Bool
    let rules: [Rule]
}

struct AutomationNight: Codable, Identifiable, Sendable {
    let sleepRecordId: Int
    let label: String
    let date: String
    let startMs: Double
    let endMs: Double
    var id: Int { sleepRecordId }
}

struct AutomationBacktestRequest: Encodable, Sendable {
    struct Rule: Encodable, Sendable {
        let definition: AutomationDefinition
        enum CodingKeys: CodingKey { case side, cooldownMin, trigger, conditions, actions }
        func encode(to encoder: Encoder) throws {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(definition.side, forKey: .side); try fields.encode(definition.cooldownMin, forKey: .cooldownMin)
            try fields.encode(definition.trigger, forKey: .trigger); try fields.encode(definition.conditions, forKey: .conditions)
            try fields.encode(definition.actions, forKey: .actions)
        }
    }
    let side: Side
    let sleepRecordId: Int?
    let stepMin = 2
    let rule: Rule
}

struct AutomationBacktest: Decodable, Sendable {
    struct Night: Codable, Sendable { let label: String; let date: String }
    struct Result: Decodable, Sendable {
        struct Series: Decodable, Sendable { let key: String; let label: String; let values: [Double?] }
        struct Axis: Decodable, Sendable { let min: Double; let max: Double; let unit: String? }
        struct TimeWindow: Decodable, Sendable { let startMin: Double; let endMin: Double }
        struct Summary: Decodable, Sendable {
            let wouldFire: Int; let suppressed: Int; let clampHits: Int; let label: String
            let netEffect: String?; let setpointRange: [Double]?
        }
        let mode: String
        let stepMin: Int
        let clockMin: [Double]
        let primary: Series?
        let avg: Series?
        let threshold: Double?
        let setpoint: [Double?]
        let setpointRaw: [Double?]?
        let clamp: AutomationAction.Clamp?
        let timeWindow: TimeWindow?
        let fires: [Int]
        let suppressed: [Int]
        let primaryAxis: Axis?
        let tempAxis: Axis?
        let summary: Summary
    }
    let ok: Bool
    let message: String?
    let night: Night?
    let result: Result?
}

struct AutomationTonight: Decodable, Sendable {
    struct Hold: Decodable, Sendable { let temperature: Double; let startedAt: Double; let expiresAt: Double }
    struct Last: Decodable, Sendable { let ruleName: String; let temp: Double; let at: Double }
    struct State: Decodable, Sendable {
        let control: TemperatureControlStatus?
        let hold: Hold?
        let runOnceUntil: Double?
        let lastAutopilot: Last?
    }
    struct Sides: Decodable, Sendable { let left: State; let right: State }
    let now: Double
    let sides: Sides
}
