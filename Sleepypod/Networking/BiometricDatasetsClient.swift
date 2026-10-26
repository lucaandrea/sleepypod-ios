import Foundation

protocol BiometricDatasetsServing: Sendable {
    var scope: String { get }
    func sessions(side: Side, cursor: ReplaySessionPage.Cursor?) async throws -> ReplaySessionPage
    func capabilities(side: Side, id: Int) async throws -> ReplaySessionCapabilities
    func references(side: Side, cursor: ReferenceLibraryPage.Cursor?) async throws -> ReferenceLibraryPage
    func datasets(side: Side, cursor: BiometricDatasetPage.Cursor?) async throws -> BiometricDatasetPage
    func dataset(id: String) async throws -> BiometricDataset
    func create(_ request: BiometricDatasetRequest) async throws -> BiometricDataset
    func release(id: String) async throws -> BiometricDataset
}
struct CoreBiometricDatasetsClient: BiometricDatasetsServing {
    let transport: CoreRESTClient
    var scope: String { transport.endpoint.absoluteString }
    private let root = "biometric-tuning"
    func sessions(side: Side, cursor: ReplaySessionPage.Cursor?) async throws -> ReplaySessionPage {
        var query = ["side": side.rawValue]
        if let cursor {
            guard cursor.id > 0 else { throw BiometricBacktestInput.error("Invalid session cursor.") }
            query["beforeStartMs"] = try BiometricBacktestInput.milliseconds(cursor.startMs); query["beforeId"] = String(cursor.id)
        }
        return try await transport.get("\(root)/sessions", query: query)
    }
    func capabilities(side: Side, id: Int) async throws -> ReplaySessionCapabilities {
        guard id > 0 else { throw BiometricBacktestInput.error("Invalid session identity.") }
        return try await transport.get("\(root)/sessions/\(id)/capabilities", query: ["side": side.rawValue])
    }
    func references(side: Side, cursor: ReferenceLibraryPage.Cursor?) async throws -> ReferenceLibraryPage {
        try await CoreBiometricReferencesClient(transport: transport).library(side: side, cursor: cursor)
    }
    func datasets(side: Side, cursor: BiometricDatasetPage.Cursor?) async throws -> BiometricDatasetPage {
        var query = ["side": side.rawValue]
        if let cursor {
            query["beforeCreatedAtMs"] = try BiometricBacktestInput.milliseconds(cursor.createdAtMs)
            query["beforeId"] = try BiometricBacktestInput.identifier(cursor.id)
        }
        return try await transport.get("\(root)/datasets", query: query)
    }
    func dataset(id: String) async throws -> BiometricDataset { try await transport.get("\(root)/datasets/\(BiometricBacktestInput.identifier(id))") }
    func create(_ request: BiometricDatasetRequest) async throws -> BiometricDataset {
        try await transport.post("\(root)/datasets", body: request.validated(), returning: BiometricDataset.self)
    }
    func release(id: String) async throws -> BiometricDataset {
        try await transport.post("\(root)/datasets/\(BiometricBacktestInput.identifier(id))/release", body: [String: String](), returning: BiometricDataset.self)
    }
}
