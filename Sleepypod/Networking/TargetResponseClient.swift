import Foundation

protocol TargetResponseClient: Sendable {
    func status(side: Side) async throws -> TargetResponseResearch
    func evaluate(side: Side, datasetHash: String) async throws -> TargetResponseResearch
    func preview(side: Side) async throws -> TargetResponsePreview
}

struct CoreTargetResponseClient: TargetResponseClient {
    let transport: CoreRESTClient
    func status(side: Side) async throws -> TargetResponseResearch {
        try await transport.get("v1/comfort/response/model", query: ["side": side.rawValue])
    }
    func evaluate(side: Side, datasetHash: String) async throws -> TargetResponseResearch {
        guard TargetResponseResearch.digest(datasetHash) else { throw TargetResponseResearch.invalid }
        struct Input: Encodable, Sendable { let side: Side; let expectedDatasetHash: String }
        return try await transport.post("v1/comfort/response/train", body: Input(side: side, expectedDatasetHash: datasetHash), returning: TargetResponseResearch.self)
    }
    func preview(side: Side) async throws -> TargetResponsePreview {
        try await transport.get("v1/comfort/response/preview", query: ["side": side.rawValue])
    }
}
