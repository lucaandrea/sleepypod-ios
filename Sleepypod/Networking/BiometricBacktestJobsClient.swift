import Foundation

protocol BiometricBacktestJobsServing: Sendable {
    func evaluationOverview(side: Side) async throws -> BiometricProfileOverview
    func evaluationProfiles(side: Side, cursor: BiometricProfilePage.Cursor?) async throws -> BiometricProfilePage
    func evaluationProfile(id: String) async throws -> BiometricProfileRevision
    func jobs(side: Side, cursor: BiometricBacktestPage.Cursor?) async throws -> BiometricBacktestPage
    func job(id: String) async throws -> BiometricBacktestJob
    func submit(_ request: BiometricBacktestSubmission) async throws -> BiometricBacktestJob
    func cancelJob(id: String) async throws -> BiometricBacktestJob
}

extension CoreBiometricDatasetsClient {
    func evaluationOverview(side: Side) async throws -> BiometricProfileOverview { try await CoreBiometricProfilesClient(transport: transport).overview(side: side) }
    func evaluationProfiles(side: Side, cursor: BiometricProfilePage.Cursor?) async throws -> BiometricProfilePage { try await CoreBiometricProfilesClient(transport: transport).profiles(side: side, cursor: cursor) }
    func evaluationProfile(id: String) async throws -> BiometricProfileRevision { try await CoreBiometricProfilesClient(transport: transport).profile(id: id) }
    func jobs(side: Side, cursor: BiometricBacktestPage.Cursor?) async throws -> BiometricBacktestPage {
        var query = ["side": side.rawValue]
        if let cursor {
            query["beforeCreatedAtMs"] = try BiometricBacktestInput.milliseconds(cursor.createdAtMs)
            query["beforeId"] = try BiometricBacktestInput.identifier(cursor.id)
        }
        return try await transport.get("biometric-tuning/backtests", query: query)
    }
    func job(id: String) async throws -> BiometricBacktestJob { try await transport.get("biometric-tuning/backtests/\(BiometricBacktestInput.identifier(id))") }
    func submit(_ request: BiometricBacktestSubmission) async throws -> BiometricBacktestJob {
        try await transport.post("biometric-tuning/backtests", body: request.validated(), returning: BiometricBacktestJob.self)
    }
    func cancelJob(id: String) async throws -> BiometricBacktestJob {
        try await transport.post("biometric-tuning/backtests/\(BiometricBacktestInput.identifier(id))/cancel", body: [String: String](), returning: BiometricBacktestJob.self)
    }
}
