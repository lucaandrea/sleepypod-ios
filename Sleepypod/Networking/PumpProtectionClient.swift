import Foundation

protocol PumpProtectionClient: Sendable {
    func settings() async throws -> PumpProtectionSettings
    func save(_ patch: PumpProtectionPatch) async throws -> PumpProtectionSettings
}
struct CorePumpProtectionClient: PumpProtectionClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient {
        get throws { guard let transport else { throw APIError.noBaseURL }; return transport }
    }
    func settings() async throws -> PumpProtectionSettings {
        struct Envelope: Decodable, Sendable { let device: PumpProtectionSettings }
        let response: Envelope = try await client.get("settings")
        return response.device
    }
    func save(_ patch: PumpProtectionPatch) async throws -> PumpProtectionSettings {
        try patch.validate()
        return try await client.patch("settings/device", body: patch, returning: PumpProtectionSettings.self)
    }
}
actor DemoPumpProtectionClient: PumpProtectionClient {
    private var value = PumpProtectionSettings(pumpStallProtectionEnabled: true, pumpStallRpmThreshold: 300, pumpStallDwellSamples: 3, pumpStallAutoRecoveryEnabled: true, pumpStallRecoveryRpm: 1000, pumpStallRecoverySamples: 3)
    func settings() -> PumpProtectionSettings { value }
    func save(_ patch: PumpProtectionPatch) throws -> PumpProtectionSettings {
        try patch.validate()
        value.pumpStallProtectionEnabled = patch.pumpStallProtectionEnabled ?? value.pumpStallProtectionEnabled
        value.pumpStallRpmThreshold = patch.pumpStallRpmThreshold ?? value.pumpStallRpmThreshold
        value.pumpStallDwellSamples = patch.pumpStallDwellSamples ?? value.pumpStallDwellSamples
        value.pumpStallAutoRecoveryEnabled = patch.pumpStallAutoRecoveryEnabled ?? value.pumpStallAutoRecoveryEnabled
        value.pumpStallRecoveryRpm = patch.pumpStallRecoveryRpm ?? value.pumpStallRecoveryRpm
        value.pumpStallRecoverySamples = patch.pumpStallRecoverySamples ?? value.pumpStallRecoverySamples
        return value
    }
}
