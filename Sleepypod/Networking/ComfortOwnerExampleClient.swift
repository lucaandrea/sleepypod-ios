import Foundation

struct ComfortOwnerExample: Decodable, Sendable {
    let synthetic: Bool
    let sourceCommit: String
    let statuses: [String: ComfortOwnerStatus]
    let reviews: [String: ComfortOwnerReview]
    static func load() throws -> Self {
        guard let url = Bundle.main.url(forResource: "comfort-owner-example", withExtension: "json") else { throw ComfortOwnerValidation.invalid }
        let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard result.synthetic else { throw ComfortOwnerValidation.invalid }; return result
    }
}

/// Synthetic reviews are inspectable, but never confirm physical evidence or create an owner grant.
struct ComfortOwnerExampleClient: ComfortOwnerClient {
    let scenario: String
    func status(side: Side) throws -> ComfortOwnerStatus {
        if scenario == "unavailable" { throw APIError.serverError(message: "This controller does not offer owner qualification yet.") }
        let fixture = try ComfortOwnerExample.load()
        guard let result = fixture.statuses[side == .right ? "right" : scenario] ?? fixture.statuses["initial"] else { throw ComfortOwnerValidation.invalid }
        return result
    }
    func prepare(_ input: ComfortOwnerPrepare) throws -> ComfortOwnerReview {
        guard input.side == .left, let result = try ComfortOwnerExample.load().reviews[input.kind?.rawValue ?? input.purpose.rawValue] else {
            throw APIError.serverError(message: "This synthetic review is available for the Left example only.")
        }
        return result
    }
    func confirm(_ input: ComfortOwnerConfirm) throws -> ComfortOwnerReceipt { throw APIError.serverError(message: "Demo cannot confirm physical evidence or activate comfort.") }
    func retest(_ input: ComfortOwnerRetest) throws -> ComfortOwnerReceipt { throw APIError.serverError(message: "Demo has no actual qualification to revoke.") }
}
