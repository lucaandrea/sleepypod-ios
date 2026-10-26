import Foundation

struct BiometricValidatedSelection: Codable, Equatable, Sendable {
    let side: Side
    let revisionId: String
    let expectedResolvedHash: String
    let evaluationId: String
    let expectedReportHash: String
    func validate() throws {
        _ = try BiometricBacktestInput.identifier(revisionId)
        _ = try BiometricBacktestInput.identifier(evaluationId)
        guard BiometricBacktestInput.isHash(expectedResolvedHash), BiometricBacktestInput.isHash(expectedReportHash) else {
            throw BiometricBacktestInput.error("Reload the exact candidate and retained evaluation before reviewing application.")
        }
    }
    var fields: [String: JSONValue] {
        ["side": .string(side.rawValue), "revisionId": .string(revisionId), "expectedResolvedHash": .string(expectedResolvedHash),
         "evaluationId": .string(evaluationId), "expectedReportHash": .string(expectedReportHash)]
    }
}
extension BiometricValidatedSelection {
    init(side: Side, job: BiometricBacktestJob, descriptor: BiometricReportDescriptor) throws {
        try descriptor.validate(job: job)
        let report = try descriptor.decoded(BiometricEvaluationReport.self)
        try report.validate(job: job, side: side, projection: descriptor.projection)
        guard descriptor.available, job.state == .succeeded,
              let candidate = job.configurations.first(where: { $0.label == "candidate" }), let revision = candidate.revisionId else {
            throw BiometricBacktestInput.error("This retained report does not select an exact saved candidate.")
        }
        self.init(side: side, revisionId: revision, expectedResolvedHash: candidate.hash, evaluationId: job.id, expectedReportHash: descriptor.contentHash)
        try validate()
    }
}
struct BiometricValidatedReviewRequest: Codable, Equatable, Sendable {
    let selection: BiometricValidatedSelection
    let expectedGeneration: Int
    func query() throws -> [String: String] {
        try selection.validate()
        guard (0..<9_007_199_254_740_991).contains(expectedGeneration) else { throw BiometricBacktestInput.error("The current profile generation is invalid.") }
        return ["side": selection.side.rawValue, "revisionId": selection.revisionId, "expectedResolvedHash": selection.expectedResolvedHash,
                "evaluationId": selection.evaluationId, "expectedReportHash": selection.expectedReportHash, "expectedGeneration": String(expectedGeneration)]
    }
}
struct BiometricValidatedEligibility: Decodable, Sendable { let eligible: Bool }
struct BiometricValidatedRequest: Codable, Equatable, Sendable {
    let review: BiometricValidatedReviewRequest
    let boundary: BiometricProfileBoundary
    let requester: String
    let idempotencyKey: String
    var side: Side { review.selection.side }
    func body() throws -> JSONValue {
        _ = try review.query()
        guard (1...200).contains(requester.utf16.count), (1...200).contains(idempotencyKey.utf16.count) else {
            throw BiometricBacktestInput.error("The retained activation request is invalid.")
        }
        var fields = review.selection.fields
        fields["expectedGeneration"] = .number(Double(review.expectedGeneration))
        fields["boundary"] = .string(boundary.rawValue); fields["requester"] = .string(requester)
        fields["idempotencyKey"] = .string(idempotencyKey)
        return .object(fields)
    }
    /// The public receipt omits the retry key; match its candidate, generation and verified evaluation audit.
    func confirms(_ event: BiometricActivationEvent) -> Bool {
        let selection = review.selection
        return event.side == side && event.action == "activate" && event.nextRevisionId == selection.revisionId
            && event.nextHash == selection.expectedResolvedHash && event.generation == review.expectedGeneration + 1
            && event.evaluationId == selection.evaluationId && event.requester == requester
            && event.evidence["status"] == .string("validated_reference_agreement")
            && event.evidence["version"] == .string("verified-evaluation-v1")
            && event.evidence["reportHash"] == .string(selection.expectedReportHash)
            && event.evidence["revisionId"] == .string(selection.revisionId)
            && event.evidence["resolvedHash"] == .string(selection.expectedResolvedHash)
    }
}
struct BiometricValidatedReview: Sendable {
    let request: BiometricValidatedReviewRequest
    let binding: BiometricProfileBinding
    let beforeHash: String
    let diff: BiometricProfileDiff
    let reviewedAt: Date
    func matches(_ overview: BiometricProfileOverview, now: Date = .now) -> Bool {
        overview.desired.binding == binding && overview.desired.hash == beforeHash
            && (0...60).contains(now.timeIntervalSince(reviewedAt))
    }
}
