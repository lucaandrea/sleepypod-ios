import Foundation

protocol BiometricExperimentsServing: Sendable {
    var scope: String { get }
    func experiments(side: Side, cursor: BiometricExperimentPage.Cursor?) async throws -> BiometricExperimentPage
    func experiment(id: String) async throws -> BiometricExperiment
    func create(_ request: BiometricExperimentRequest) async throws -> BiometricExperiment
}
extension CoreBiometricDatasetsClient {
    func experiments(side: Side, cursor: BiometricExperimentPage.Cursor?) async throws -> BiometricExperimentPage {
        var query = ["side": side.rawValue]
        if let cursor {
            query["beforeCreatedAtMs"] = try BiometricBacktestInput.milliseconds(cursor.createdAtMs)
            query["beforeId"] = try BiometricBacktestInput.identifier(cursor.id)
        }
        return try await transport.get("biometric-tuning/experiments", query: query)
    }
    func experiment(id: String) async throws -> BiometricExperiment {
        try await transport.get("biometric-tuning/experiments/\(BiometricBacktestInput.identifier(id))")
    }
    func create(_ request: BiometricExperimentRequest) async throws -> BiometricExperiment {
        try await transport.post("biometric-tuning/experiments", body: request.validated(), returning: BiometricExperiment.self)
    }
}
