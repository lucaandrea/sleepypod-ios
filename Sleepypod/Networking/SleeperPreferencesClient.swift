import Foundation

protocol SleeperPreferencesClient: Sendable {
    func settings() async throws -> SleeperPreferencesSnapshot
    func saveBed(_ patch: SettingsFieldPatch) async throws
    func saveSide(_ side: Side, patch: SettingsFieldPatch) async throws
    func occupancy() async throws -> SensorOccupancy
}
struct CoreSleeperPreferencesClient: SleeperPreferencesClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient { get throws { guard let transport else { throw APIError.noBaseURL }; return transport } }
    func settings() async throws -> SleeperPreferencesSnapshot { try await client.get("settings") }
    func saveBed(_ patch: SettingsFieldPatch) async throws {
        guard !patch.isEmpty, Set(patch.fields.keys).isSubset(of: ["bedMode", "unusedZoneMode"]) else { throw APIError.serverError(message: "Unsupported bed setup changes.") }
        try await client.patch("settings/device", body: patch)
    }
    func saveSide(_ side: Side, patch: SettingsFieldPatch) async throws {
        let allowed: Set<String> = ["name", "awayMode", "awayReturn", "alwaysOn", "autoOffEnabled", "autoOffMinutes", "autoOnEnabled", "autoOnMinutes", "autoOnStart", "autoOnEnd"]
        guard !patch.isEmpty, Set(patch.fields.keys).isSubset(of: allowed) else { throw APIError.serverError(message: "Unsupported sleeper changes.") }
        var fields = patch.fields; fields["side"] = .string(side.rawValue)
        try await client.patch("settings/side", body: SettingsFieldPatch(fields: fields))
    }
    func occupancy() async throws -> SensorOccupancy { try await client.get("biometrics/occupancy") }
}
actor DemoSleeperPreferencesClient: SleeperPreferencesClient {
    private var value = SleeperPreferencesSnapshot.demo
    func settings() -> SleeperPreferencesSnapshot { value }
    func saveBed(_ patch: SettingsFieldPatch) {
        if case .string(let mode) = patch.fields["bedMode"] { value.device.bedMode = mode }
        if case .string(let mode) = patch.fields["unusedZoneMode"] { value.device.unusedZoneMode = mode }
    }
    func saveSide(_ side: Side, patch: SettingsFieldPatch) throws { value.sides[side] = try value.sides[side].merging(patch) }
    func occupancy() -> SensorOccupancy {
        let side = SensorOccupancy.BedSide(occupied: false, available: true, classification: "empty", movement: .init(active: false, peakScore: 0), level: .init(active: false, deviation: nil, threshold: nil, ageMs: 1000, zoneDeviations: nil, zones: nil), vitals: .init(heartRate: nil, breathingRate: nil, humanRange: false))
        return .init(left: side, right: side)
    }
}
