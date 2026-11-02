import Foundation

protocol PersonalComfortClient: Sendable {
    func status(side: Side) async throws -> PersonalComfortStatus
    func configure(side: Side, config: PersonalComfortConfig) async throws -> PersonalComfortStatus
    func mode(side: Side, mode: String) async throws -> PersonalComfortStatus
    func feedback(side: Side, input: PersonalComfortFeedback) async throws -> PersonalComfortStatus
    func reports(side: Side) async throws -> ComfortNightList
    func report(side: Side, id: String, after: Int?) async throws -> ComfortNightDetail
    func review(_ input: ComfortReviewInput) async throws -> ComfortNightReview
    func thermalModel(side: Side) async throws -> ThermalModelStatus
    func trainThermalModel(side: Side, datasetHash: String) async throws -> ThermalModelStatus
}
extension PersonalComfortClient {
    func thermalModel(side: Side) async throws -> ThermalModelStatus {
        throw APIError.serverError(message: "This controller does not offer on-Pod temperature training.")
    }
    func trainThermalModel(side: Side, datasetHash: String) async throws -> ThermalModelStatus {
        throw APIError.serverError(message: "This controller does not offer on-Pod temperature training.")
    }
    func mode(side: Side, mode: String) async throws -> PersonalComfortStatus {
        throw APIError.serverError(message: "This controller does not support a mode-only comfort change.")
    }
}
struct CorePersonalComfortClient: PersonalComfortClient {
    let transport: CoreRESTClient
    func thermalModel(side: Side) async throws -> ThermalModelStatus {
        try await transport.get("v1/comfort/model", query: ["side": side.rawValue])
    }
    func trainThermalModel(side: Side, datasetHash: String) async throws -> ThermalModelStatus {
        guard ComfortReviewInput.validDigest(datasetHash) else { throw APIError.serverError(message: "Check training nights again before fitting.") }
        struct Input: Encodable, Sendable { let side: Side; let expectedDatasetHash: String }
        return try await transport.post("v1/comfort/model/train", body: Input(side: side, expectedDatasetHash: datasetHash), returning: ThermalModelStatus.self)
    }
    func status(side: Side) async throws -> PersonalComfortStatus { try await transport.get("v1/comfort", query: ["side": side.rawValue]) }
    func configure(side: Side, config: PersonalComfortConfig) async throws -> PersonalComfortStatus {
        struct Input: Encodable, Sendable { let side: Side; let config: PersonalComfortConfig }
        try config.validate()
        return try await transport.post("v1/comfort/configure", body: Input(side: side, config: config), returning: PersonalComfortStatus.self)
    }
    func mode(side: Side, mode: String) async throws -> PersonalComfortStatus {
        guard ["off", "preview"].contains(mode) else { throw APIError.serverError(message: "Active comfort adjustments are not available.") }
        struct Input: Encodable, Sendable { let side: Side; let mode: String }
        return try await transport.post("v1/comfort/mode", body: Input(side: side, mode: mode), returning: PersonalComfortStatus.self)
    }
    func feedback(side: Side, input: PersonalComfortFeedback) async throws -> PersonalComfortStatus {
        struct Input: Encodable, Sendable { let side: Side; let feedback: PersonalComfortFeedback }
        return try await transport.post("v1/comfort/feedback", body: Input(side: side, feedback: input), returning: PersonalComfortStatus.self)
    }
    func reports(side: Side) async throws -> ComfortNightList { try await transport.get("v1/comfort/reports", query: ["side": side.rawValue]) }
    func report(side: Side, id: String, after: Int?) async throws -> ComfortNightDetail {
        guard ComfortReviewInput.validDigest(id) else { throw APIError.serverError(message: "This report identifier is invalid.") }
        var query = ["side": side.rawValue, "id": id]
        if let after { query["afterId"] = String(after) }
        return try await transport.get("v1/comfort/report", query: query)
    }
    func review(_ input: ComfortReviewInput) async throws -> ComfortNightReview {
        try await transport.post("v1/comfort/report/review", body: input, returning: ComfortNightReview.self)
    }
}
