import Foundation

protocol NightPhaseClient: Sendable {
    func rows(side: Side) async throws -> CoreScheduleRows
    func apply(_ batch: NightPhaseBatch) async throws
}
struct CoreNightPhaseClient: NightPhaseClient {
    let transport: CoreRESTClient
    func rows(side: Side) async throws -> CoreScheduleRows {
        try await transport.get("schedules", query: ["side": side.rawValue, "unit": "F"])
    }
    func apply(_ batch: NightPhaseBatch) async throws {
        struct Receipt: Decodable, Sendable { let success: Bool }
        let receipt = try await transport.post("schedules/batch", body: batch, returning: Receipt.self)
        guard receipt.success else { throw APIError.serverError(message: "The controller did not confirm the schedule edit. Reload to check its outcome.") }
    }
}

/// The demo uses the same phase math while keeping its edits in the shared mock schedule.
actor DemoNightPhaseClient: NightPhaseClient {
    let api: any SleepypodProtocol
    private var cached: [Side: CoreScheduleRows] = [:]
    private var nextID = 20000
    private var previousWrite: Task<Void, Error>?
    private let scenario: String
    init(api: any SleepypodProtocol, scenario: String = "complete") { self.api = api; self.scenario = scenario }
    func rows(side: Side) async throws -> CoreScheduleRows {
        if scenario == "partial" { throw APIError.serverError(message: "Example controller is offline.") }
        if let rows = cached[side] { return rows }
        if scenario == "empty" { cached[side] = .init(); return .init() }
        let schedule = try await api.getSchedules().schedule(for: side)
        var rows = CoreScheduleRows(), identifier = side == .left ? 0 : 10000
        for day in DayOfWeek.allCases {
            let daily = schedule[day]
            for (time, value) in daily.temperatures.sorted(by: { $0.key < $1.key }) {
                identifier += 1
                rows.temperature.append(.init(id: identifier, side: side.rawValue, dayOfWeek: day.rawValue, time: time, temperature: Double(value), enabled: true))
            }
            identifier += 1
            rows.power.append(.init(id: identifier, side: side.rawValue, dayOfWeek: day.rawValue, onTime: daily.power.on, offTime: daily.power.off, onTemperature: Double(daily.power.onTemperature), enabled: daily.power.enabled, endAction: daily.power.endAction, offDayOffset: daily.power.offDayOffset))
        }
        cached[side] = rows
        return rows
    }
    func apply(_ batch: NightPhaseBatch) async throws {
        let previous = previousWrite
        let task = Task { [self] in
            _ = try? await previous?.value
            try await perform(batch)
        }
        previousWrite = task
        try await task.value
    }
    private func perform(_ batch: NightPhaseBatch) async throws {
        for side in Side.allCases { _ = try await rows(side: side) }
        var schedules = try await api.getSchedules()
        for side in Side.allCases {
            var rows = cached[side] ?? .init()
            rows.temperature.removeAll { batch.deletes.temperature.contains($0.id) }
            rows.power.removeAll { batch.deletes.power.contains($0.id) }
            for update in batch.updates.temperature {
                if let index = rows.temperature.firstIndex(where: { $0.id == update.id }) { rows.temperature[index].temperature = update.temperature }
            }
            for created in batch.creates.temperature where created.side == side {
                nextID += 1
                rows.temperature.append(.init(id: nextID, side: side.rawValue, dayOfWeek: created.dayOfWeek, time: created.time, temperature: created.temperature, enabled: true))
            }
            for created in batch.creates.power where created.side == side {
                nextID += 1
                rows.power.append(.init(id: nextID, side: side.rawValue, dayOfWeek: created.dayOfWeek, onTime: created.onTime, offTime: created.offTime, onTemperature: created.onTemperature, enabled: true, endAction: created.endAction))
            }
            cached[side] = rows
            var schedule = schedules.schedule(for: side)
            let projected = rows.projected
            for day in DayOfWeek.allCases { schedule[day].temperatures = projected[day].temperatures; schedule[day].power = projected[day].power }
            schedules.setSchedule(schedule, for: side)
        }
        _ = try await api.updateSchedules(schedules, days: nil)
    }
}
