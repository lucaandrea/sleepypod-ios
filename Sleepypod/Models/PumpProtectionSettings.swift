import Foundation

struct PumpProtectionSettings: Codable, Equatable, Sendable {
    var pumpStallProtectionEnabled: Bool
    var pumpStallRpmThreshold: Int
    var pumpStallDwellSamples: Int
    var pumpStallAutoRecoveryEnabled: Bool
    var pumpStallRecoveryRpm: Int
    var pumpStallRecoverySamples: Int
    func patch(from saved: Self) -> PumpProtectionPatch {
        .init(pumpStallProtectionEnabled: pumpStallProtectionEnabled == saved.pumpStallProtectionEnabled ? nil : pumpStallProtectionEnabled,
              pumpStallRpmThreshold: pumpStallRpmThreshold == saved.pumpStallRpmThreshold ? nil : pumpStallRpmThreshold,
              pumpStallDwellSamples: pumpStallDwellSamples == saved.pumpStallDwellSamples ? nil : pumpStallDwellSamples,
              pumpStallAutoRecoveryEnabled: pumpStallAutoRecoveryEnabled == saved.pumpStallAutoRecoveryEnabled ? nil : pumpStallAutoRecoveryEnabled,
              pumpStallRecoveryRpm: pumpStallRecoveryRpm == saved.pumpStallRecoveryRpm ? nil : pumpStallRecoveryRpm,
              pumpStallRecoverySamples: pumpStallRecoverySamples == saved.pumpStallRecoverySamples ? nil : pumpStallRecoverySamples)
    }
}
struct PumpProtectionPatch: Encodable, Sendable {
    let pumpStallProtectionEnabled: Bool?
    let pumpStallRpmThreshold: Int?
    let pumpStallDwellSamples: Int?
    let pumpStallAutoRecoveryEnabled: Bool?
    let pumpStallRecoveryRpm: Int?
    let pumpStallRecoverySamples: Int?
    func validate() throws {
        guard pumpStallRpmThreshold.map({ (100...1500).contains($0) }) ?? true,
              pumpStallDwellSamples.map({ (1...10).contains($0) }) ?? true,
              pumpStallRecoveryRpm.map({ (500...3000).contains($0) }) ?? true,
              pumpStallRecoverySamples.map({ (1...10).contains($0) }) ?? true else {
            throw APIError.serverError(message: "Pump protection values are outside the controller's supported ranges.")
        }
    }
}
