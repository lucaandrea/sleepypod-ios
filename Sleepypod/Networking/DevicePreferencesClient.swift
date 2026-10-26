import Foundation

protocol DevicePreferencesClient: Sendable {
    func settings() async throws -> DevicePreferences
    func save(_ patch: SettingsFieldPatch) async throws
    func sensorSource() async throws -> SensorSourceSnapshot
    func restart() async throws -> HealthServiceRestart
}
struct CoreDevicePreferencesClient: DevicePreferencesClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient { get throws { guard let transport else { throw APIError.noBaseURL }; return transport } }
    func settings() async throws -> DevicePreferences {
        struct Envelope: Decodable, Sendable { let device: DevicePreferences }
        let response: Envelope = try await client.get("settings")
        return response.device
    }
    func save(_ patch: SettingsFieldPatch) async throws {
        guard !patch.isEmpty, Set(patch.fields.keys).isSubset(of: Set(DevicePreferences.CodingKeys.allCases.map(\.rawValue))) else { throw APIError.serverError(message: "No supported device changes to save.") }
        try await client.patch("settings/device", body: patch)
    }
    func sensorSource() async throws -> SensorSourceSnapshot { try await client.get("system/sensor-source") }
    func restart() async throws -> HealthServiceRestart {
        try await client.post("health/restart-service", body: ["unit": "sleepypod.service"], returning: HealthServiceRestart.self)
    }
}
actor DemoDevicePreferencesClient: DevicePreferencesClient {
    private var value = DevicePreferences.demo
    func settings() -> DevicePreferences { value }
    func save(_ patch: SettingsFieldPatch) throws {
        var fields = value.fields
        fields.merge(patch.fields) { _, newValue in newValue }
        let next = try JSONDecoder().decode(DevicePreferences.self, from: JSONEncoder().encode(fields))
        if let issue = next.issue { throw APIError.serverError(message: issue) }
        value = next
    }
    func sensorSource() -> SensorSourceSnapshot { .demo }
    func restart() -> HealthServiceRestart { .init(ok: true, message: "Simulated restart requested. No service was restarted.") }
}
