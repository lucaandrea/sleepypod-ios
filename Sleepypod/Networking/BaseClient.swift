import Foundation

protocol BaseClient: Sendable {
    func status() async throws -> UnifiedBaseStatus
    func move(_ request: BaseMoveRequest) async throws
    func stop() async throws
    func reconnect() async throws
    func schedules() async throws -> [BaseSchedule]
    func save(_ schedule: BaseSchedule) async throws -> BaseSchedule
    func delete(_ id: Int) async throws
}

struct CoreBaseClient: BaseClient {
    let client: CoreRESTClient
    func status() async throws -> UnifiedBaseStatus { try await client.get("base/status") }
    func move(_ request: BaseMoveRequest) async throws { try await client.post("base/position", body: request) }
    func stop() async throws { try await client.post("base/stop", body: [String: String]()) }
    func reconnect() async throws { try await client.post("base/reconnect", body: [String: String]()) }
    func schedules() async throws -> [BaseSchedule] { try await client.get("base/schedules") }
    func save(_ schedule: BaseSchedule) async throws -> BaseSchedule {
        try await client.post("base/schedules", body: schedule, returning: BaseSchedule.self)
    }
    func delete(_ id: Int) async throws { try await client.delete("base/schedules/\(id)") }
}

/// A local simulation, isolated from the configured controller and its credentials.
actor DemoBaseClient: BaseClient {
    private let scenario: String
    init(scenario: String = "whole") { self.scenario = scenario }
    private var position = BasePositions(left: BasePreset.relax.angles, right: BasePreset.relax.angles)
    private var rows = [BaseSchedule(id: 1)]
    private var nextID = 2
    func status() -> UnifiedBaseStatus {
        if scenario == "offline" {
            return UnifiedBaseStatus(state: "disconnected", position: nil, stale: true, busy: false, error: "The base is disconnected.", independentControl: false)
        }
        return UnifiedBaseStatus(state: "connected", position: position, stale: false, busy: false,
                          lastUpdate: Date().timeIntervalSince1970 * 1000, independentControl: scenario == "independent",
                          movingBySide: .init(left: false, right: false), moving: false, splitBase: scenario == "independent")
    }
    func move(_ request: BaseMoveRequest) {
        for side in request.sides {
            position[BaseScope(rawValue: side) ?? .both] = BaseAngles(head: Double(request.head), feet: Double(request.feet))
        }
    }
    func stop() {}
    func reconnect() {}
    func schedules() -> [BaseSchedule] { rows }
    func save(_ schedule: BaseSchedule) throws -> BaseSchedule {
        guard !rows.contains(where: { schedule.conflicts(with: $0) }) else {
            throw APIError.serverError(message: "An adjustment already exists for this side at this day and time.")
        }
        var saved = schedule
        if saved.id == nil { saved.id = nextID; nextID += 1 }
        rows.removeAll { $0.id == saved.id }; rows.append(saved)
        return saved
    }
    func delete(_ id: Int) { rows.removeAll { $0.id == id } }
}
