import Foundation

protocol PumpAlertClient: Sendable {
    func list(includeAcknowledged: Bool) async throws -> [PumpAlert]
    func dismiss(id: Int) async throws
}
struct CorePumpAlertClient: PumpAlertClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient {
        get throws { guard let transport else { throw APIError.noBaseURL }; return transport }
    }
    func list(includeAcknowledged: Bool) async throws -> [PumpAlert] {
        try await client.get("pump-alerts", query: ["limit": "500", "includeAcknowledged": String(includeAcknowledged)])
    }
    func dismiss(id: Int) async throws {
        struct Acknowledgement: Decodable, Sendable { let success: Bool }
        let result = try await client.post("pump-alerts/dismiss", body: ["id": id], returning: Acknowledgement.self)
        guard result.success else { throw APIError.serverError(message: "The controller did not confirm dismissal.") }
    }
}
actor DemoPumpAlertClient: PumpAlertClient {
    private var dismissed: Set<Int> = []
    private let timestamp = Date.now.addingTimeInterval(-3600).ISO8601Format()
    func list(includeAcknowledged: Bool) -> [PumpAlert] {
        let values = [
            PumpAlert(id: 101, timestamp: timestamp, type: "stall_left", side: .left, rpm: 40, flowrateCd: nil, durationSeconds: 18, action: "power_off", restoreTargetTemperature: 74, restoreDurationSeconds: 3600, acknowledgedAt: nil, dismissedAt: nil),
            PumpAlert(id: 102, timestamp: timestamp, type: "asymmetry", side: nil, rpm: nil, flowrateCd: 2.4, durationSeconds: 60, action: "warned", restoreTargetTemperature: nil, restoreDurationSeconds: nil, acknowledgedAt: nil, dismissedAt: nil),
            PumpAlert(id: 100, timestamp: timestamp, type: "no_flow_right", side: .right, rpm: 800, flowrateCd: 0, durationSeconds: 20, action: "auto_recovered", restoreTargetTemperature: nil, restoreDurationSeconds: nil, acknowledgedAt: timestamp, dismissedAt: nil)
        ]
        return values.filter { !dismissed.contains($0.id) && (includeAcknowledged || $0.acknowledgedAt == nil) }
    }
    func dismiss(id: Int) { dismissed.insert(id) }
}
