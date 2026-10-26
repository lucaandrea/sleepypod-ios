import Foundation

protocol PersonalComfortClient: Sendable {
    func status(side: Side) async throws -> PersonalComfortStatus
    func configure(side: Side, config: PersonalComfortConfig) async throws -> PersonalComfortStatus
    func feedback(side: Side, input: PersonalComfortFeedback) async throws -> PersonalComfortStatus
    func reports(side: Side) async throws -> ComfortNightList
    func report(side: Side, id: String, after: Int?) async throws -> ComfortNightDetail
    func review(_ input: ComfortReviewInput) async throws -> ComfortNightReview
}
struct CorePersonalComfortClient: PersonalComfortClient {
    let transport: CoreRESTClient
    func status(side: Side) async throws -> PersonalComfortStatus { try await transport.get("v1/comfort", query: ["side": side.rawValue]) }
    func configure(side: Side, config: PersonalComfortConfig) async throws -> PersonalComfortStatus {
        struct Input: Encodable, Sendable { let side: Side; let config: PersonalComfortConfig }
        try config.validate()
        return try await transport.post("v1/comfort/configure", body: Input(side: side, config: config), returning: PersonalComfortStatus.self)
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
