import Foundation

/// Explicit synthetic UI evidence; ordinary Demo does not use these recorded outcomes.
struct AutomationDiagnosticsExample: Decodable {
    struct Example: Decodable {
        let name: String
        let rows: [AutomationDiagnostics.Run]
        let now: Double
        let startOfDay: Double
    }
    let synthetic: Bool
    let cases: [Example]
    static func snapshot(rules: [AutomationRule], enabled: Bool) -> AutomationDiagnostics? {
        guard let url = Bundle.main.url(forResource: "automation-diagnostics-fixtures", withExtension: "json"),
              let data = try? Data(contentsOf: url), let fixture = try? JSONDecoder().decode(Self.self, from: data), fixture.synthetic,
              let outcomes = fixture.cases.first(where: { $0.name == "all-outcomes-rank-and-count" }),
              let longLog = fixture.cases.first(where: { $0.name == "many-log-groups" }) else { return nil }
        func iso(_ milliseconds: Double) -> String { Date(timeIntervalSince1970: milliseconds / 1000).ISO8601Format() }
        return .init(now: iso(outcomes.now), since: iso(outcomes.now - 10_800_000), startOfDay: iso(outcomes.startOfDay), globalEnabled: enabled,
                     rules: rules.map { rule in
                         .init(rule: rule, runs: rule.id == 1 ? outcomes.rows : longLog.rows,
                               signals: rule.id == 1 ? ["ambient.temperature": 74] : ["right.movement": nil])
                     })
    }
}
