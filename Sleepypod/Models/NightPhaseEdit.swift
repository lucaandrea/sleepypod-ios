import Foundation

struct NightPhaseSnapshot: Sendable {
    let side: Side
    let rows: CoreScheduleRows
    let phases: NightPhases
    let template: [CoreTemperatureRow]
    static func make(side: Side, rows: CoreScheduleRows, now: Date, timezone: String) throws -> Self {
        try NightPhaseProjection.validate(rows, side: side)
        if let phases = NightPhaseProjection.phases(rows: rows, now: now, timezone: timezone) {
            return .init(side: side, rows: rows, phases: phases, template: [])
        }
        let generated = ScheduleCurveAlgorithm.temperatures(bedtimeMinutes: 1320, wakeMinutes: 420)
        var identifier = 0
        let template = DayOfWeek.allCases.filter { day in !rows.temperature.contains { $0.enabled && $0.dayOfWeek == day.rawValue } }.flatMap { day in
            CurvePoint.ordered(generated.map { CurvePoint(time: $0.key, temperature: $0.value) }).map { point in
                identifier -= 1
                return CoreTemperatureRow(id: identifier, side: side.rawValue, dayOfWeek: day.rawValue, time: point.time, temperature: min(110, max(55, point.temperature)), enabled: true)
            }
        }
        guard let phases = NightPhaseProjection.phases(rows: .init(temperature: template), now: now, timezone: timezone, draft: true) else {
            throw APIError.serverError(message: "No nightly phases could be prepared. Reload the schedule.")
        }
        return .init(side: side, rows: rows, phases: phases, template: template)
    }
    /// Check all temperature/power rows: a new matching day can change which days this edit owns.
    func batch(latest: CoreScheduleRows, targets: [NightPhaseKey: Int], now: Date, timezone: String, endAction: ScheduleEndAction) throws -> NightPhaseBatch {
        try NightPhaseProjection.validate(latest, side: side)
        guard NightPhaseProjection.currentDay(now: now, timezone: timezone) == phases.day,
              latest.temperature.sorted(by: { $0.id < $1.id }) == rows.temperature.sorted(by: { $0.id < $1.id }),
              latest.power.sorted(by: { $0.id < $1.id }) == rows.power.sorted(by: { $0.id < $1.id }) else {
            throw APIError.serverError(message: "The nightly schedule changed. Reload and review your unsaved temperatures.")
        }
        guard !targets.isEmpty, targets.allSatisfy({ (55...110).contains($0.value) && phases.phase($0.key) != nil }) else {
            throw APIError.serverError(message: "Choose an available phase and a temperature from 55°F to 110°F.")
        }
        var batch = NightPhaseBatch()
        if template.isEmpty {
            let shifted = NightPhaseProjection.shifted(rows: rows.temperature, phases: phases, targets: targets)
            batch.updates.temperature = zip(rows.temperature, shifted).compactMap { original, changed in
                original.temperature == changed.temperature ? nil : .init(id: original.id, temperature: changed.temperature)
            }
        } else {
            let shifted = NightPhaseProjection.shifted(rows: template, phases: phases, targets: targets)
            let days = Set(template.map(\.dayOfWeek))
            batch.deletes.temperature = rows.temperature.filter { days.contains($0.dayOfWeek) }.map(\.id)
            batch.deletes.power = rows.power.filter { days.contains($0.dayOfWeek) }.map(\.id)
            batch.creates.temperature = shifted.map { .init(side: side, dayOfWeek: $0.dayOfWeek, time: $0.time, temperature: $0.temperature) }
            batch.creates.power = DayOfWeek.allCases.filter { days.contains($0.rawValue) }.compactMap { day in
                let ordered = CurvePoint.ordered(shifted.filter { $0.dayOfWeek == day.rawValue }.map { .init(time: $0.time, temperature: $0.temperature) })
                guard let first = ordered.first, let last = ordered.last, first.time != last.time else { return nil }
                return .init(side: side, dayOfWeek: day.rawValue, onTime: first.time, offTime: last.time, onTemperature: first.temperature, endAction: endAction)
            }
        }
        return batch
    }
}

struct NightPhaseBatch: Encodable, Sendable {
    struct TemperatureUpdate: Encodable, Sendable { let id: Int; let temperature: Double }
    struct TemperatureCreate: Encodable, Sendable { let side: Side; let dayOfWeek: String; let time: String; let temperature: Double; var enabled = true }
    struct PowerCreate: Encodable, Sendable { let side: Side; let dayOfWeek: String; let onTime: String; let offTime: String; let onTemperature: Double; let endAction: ScheduleEndAction; var enabled = true }
    struct Deletes: Encodable, Sendable { var temperature: [Int] = []; var power: [Int] = []; var alarm: [Int] = [] }
    struct Creates: Encodable, Sendable { var temperature: [TemperatureCreate] = []; var power: [PowerCreate] = []; var alarm: [Int] = [] }
    struct Updates: Encodable, Sendable { var temperature: [TemperatureUpdate] = []; var power: [Int] = []; var alarm: [Int] = [] }
    var deletes = Deletes(); var creates = Creates(); var updates = Updates()
    /// An HTTP success is insufficient: every requested value must appear in the readback.
    func matches(_ rows: CoreScheduleRows, side: Side) -> Bool {
        updates.temperature.allSatisfy { update in rows.temperature.contains { $0.id == update.id && $0.temperature == update.temperature } }
        && deletes.temperature.allSatisfy { identifier in !rows.temperature.contains { $0.id == identifier } }
        && deletes.power.allSatisfy { identifier in !rows.power.contains { $0.id == identifier } }
        && creates.temperature.filter { $0.side == side }.allSatisfy { created in
            rows.temperature.contains { $0.side == side.rawValue && $0.dayOfWeek == created.dayOfWeek && $0.time == created.time && $0.temperature == created.temperature && $0.enabled }
        }
        && creates.power.filter { $0.side == side }.allSatisfy { created in
            rows.power.contains { $0.side == side.rawValue && $0.dayOfWeek == created.dayOfWeek && $0.onTime == created.onTime && $0.offTime == created.offTime && $0.onTemperature == created.onTemperature && $0.endAction == created.endAction && $0.enabled }
        }
    }
    var isEmpty: Bool { deletes.temperature.isEmpty && deletes.power.isEmpty && creates.temperature.isEmpty && creates.power.isEmpty && updates.temperature.isEmpty }
}
