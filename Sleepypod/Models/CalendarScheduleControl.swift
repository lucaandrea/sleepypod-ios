import Foundation

/// The global switch changes only enabled flags, across all seven days on one explicit side.
struct CalendarScheduleControl: Identifiable, Sendable {
    let id = UUID()
    let side: Side
    let original: CoreScheduleRows
    let enabled: Bool
    struct Update: Encodable, Sendable { let id: Int; let enabled: Bool }
    struct Updates: Encodable, Sendable { let temperature: [Update]; let power: [Update]; let alarm: [Update] }
    struct Batch: Encodable, Sendable { let updates: Updates }
    var batch: Batch { .init(updates: .init(temperature: original.temperature.map { .init(id: $0.id, enabled: enabled) }, power: original.power.map { .init(id: $0.id, enabled: enabled) }, alarm: original.alarm.map { .init(id: $0.id, enabled: enabled) })) }
    var desired: CoreScheduleRows {
        var rows = original
        for index in rows.temperature.indices { rows.temperature[index].enabled = enabled }
        for index in rows.power.indices { rows.power[index].enabled = enabled }
        for index in rows.alarm.indices { rows.alarm[index].enabled = enabled }
        return rows
    }
    static func isEnabled(_ rows: CoreScheduleRows) -> Bool { rows.temperature.contains(where: \.enabled) || rows.power.contains(where: \.enabled) || rows.alarm.contains(where: \.enabled) }
    static func same(_ first: CoreScheduleRows, _ second: CoreScheduleRows) -> Bool {
        first.temperature.sorted { $0.id < $1.id } == second.temperature.sorted { $0.id < $1.id }
        && first.power.sorted { $0.id < $1.id } == second.power.sorted { $0.id < $1.id }
        && first.alarm.sorted { $0.id < $1.id } == second.alarm.sorted { $0.id < $1.id }
    }
    static func validate(_ rows: CoreScheduleRows, side: Side) throws {
        let identifiers = [rows.temperature.map(\.id), rows.power.map(\.id), rows.alarm.map(\.id)]
        guard identifiers.allSatisfy({ Set($0).count == $0.count && $0.allSatisfy { $0 > 0 } }),
              rows.temperature.allSatisfy({ $0.side == side.rawValue }), rows.power.allSatisfy({ $0.side == side.rawValue }), rows.alarm.allSatisfy({ $0.side == side }) else {
            throw APIError.serverError(message: "The controller returned an inconsistent schedule. Reload before changing it.")
        }
    }
    static func hasRows(_ rows: CoreScheduleRows) -> Bool { !rows.temperature.isEmpty || !rows.power.isEmpty || !rows.alarm.isEmpty }
}
