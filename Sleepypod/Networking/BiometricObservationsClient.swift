import Foundation

protocol BiometricObservationsServing: Sendable {
    var scope: String { get }
    var profilesClient: any BiometricProfilesServing { get }
    func templates() async throws -> BiometricObservationTemplates
    func prepare(_ input: BiometricObservationPreparation) async throws -> BiometricObservationPrepared
    func create(_ input: BiometricObservationSubmission) async throws -> BiometricObservationRun
    func list(side: Side, afterId: String?) async throws -> BiometricObservationPage
    func get(id: String) async throws -> BiometricObservationRun
    func stop(id: String) async throws -> BiometricObservationStop
    func report(id: String) async throws -> BiometricObservationReport
    func compare(_ input: BiometricObservationReference) async throws -> BiometricObservationReport
}
struct CoreBiometricObservationsClient: BiometricObservationsServing {
    let transport: CoreRESTClient
    var scope: String { transport.endpoint.absoluteString }
    var profilesClient: any BiometricProfilesServing { CoreBiometricProfilesClient(transport: transport) }
    private let root = "biometric-tuning"
    func templates() async throws -> BiometricObservationTemplates { try await transport.get("\(root)/shadow-templates") }
    func prepare(_ input: BiometricObservationPreparation) async throws -> BiometricObservationPrepared {
        try input.validate(maximumWindowMs: 604800000)
        return try await transport.post("\(root)/shadow-plans/prepare", body: input.body, returning: BiometricObservationPrepared.self)
    }
    func create(_ input: BiometricObservationSubmission) async throws -> BiometricObservationRun {
        try await transport.post("\(root)/shadow-runs", body: input.body(), returning: BiometricObservationRun.self)
    }
    func list(side: Side, afterId: String?) async throws -> BiometricObservationPage {
        var query = ["side": side.rawValue, "maximumRuns": "20"]
        if let afterId { query["afterId"] = try BiometricBacktestInput.identifier(afterId) }
        return try await transport.get("\(root)/shadow-runs", query: query)
    }
    func get(id: String) async throws -> BiometricObservationRun { try await transport.get("\(root)/shadow-runs/\(BiometricBacktestInput.identifier(id))") }
    func stop(id: String) async throws -> BiometricObservationStop { try await transport.post("\(root)/shadow-runs/\(BiometricBacktestInput.identifier(id))/stop", body: JSONValue.object([:]), returning: BiometricObservationStop.self) }
    func report(id: String) async throws -> BiometricObservationReport { try await transport.get("\(root)/shadow-runs/\(BiometricBacktestInput.identifier(id))/report") }
    func compare(_ input: BiometricObservationReference) async throws -> BiometricObservationReport { try await transport.post("\(root)/shadow-runs/\(BiometricBacktestInput.identifier(input.run.id))/compare", body: input.body(), returning: BiometricObservationReport.self) }
}
