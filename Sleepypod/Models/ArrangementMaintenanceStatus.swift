import Foundation

struct ArrangementMaintenanceStatus: Codable, Equatable, Sendable {
    struct Operation: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable { case held, committed, completed, cancelled }
        enum Admission: String, Codable, Sendable {
            case thisTransition = "held_for_this_transition"
            case anotherTransition = "held_for_another_transition"
            case open, unavailable
        }
        let operationId: String
        let reviewId: String
        let state: State
        let createdAt: Int64
        let committedAt: Int64?
        let controllerRestarted: Bool?
        let admission: Admission
        let recovery: ArrangementRecoveryReceipt?
        let cancellation: ArrangementCancellationReceipt?
        let restart: ArrangementRestartReceipt?

        var pending: Bool { state == .held || state == .committed }
        static let fields: Set<String> = ["operationId", "reviewId", "state", "createdAt", "committedAt", "controllerRestarted", "admission", "recovery", "cancellation", "restart"]
        func validate(observedAt: Int64, expectedOperationId: String?) throws {
            guard [operationId, reviewId].allSatisfy(HouseholdValidation.identifier),
                  expectedOperationId == nil || expectedOperationId == operationId,
                  PersonalControlRequest.validInstant(createdAt), createdAt <= observedAt,
                  (state == .held || state == .cancelled) == (committedAt == nil),
                  committedAt.map({ PersonalControlRequest.validInstant($0) && $0 >= createdAt && $0 <= observedAt }) ?? true,
                  (state == .completed) == (recovery != nil), (state == .cancelled) == (cancellation != nil) else { throw HouseholdFailure.invalid }
            if let recovery {
                try recovery.validate()
                guard recovery.operationId == operationId, recovery.reviewId == reviewId,
                      recovery.completedAt <= observedAt, recovery.completedAt >= (committedAt ?? createdAt) else { throw HouseholdFailure.invalid }
            }
            if let cancellation {
                try cancellation.validate()
                guard cancellation.operationId == operationId, cancellation.reviewId == reviewId,
                      cancellation.completedAt >= createdAt, cancellation.completedAt <= observedAt else { throw HouseholdFailure.invalid }
            }
            if let restart {
                try restart.validate()
                guard restart.operationId == operationId, restart.requestedAt >= createdAt, restart.requestedAt <= observedAt,
                      restart.resultAt.map({ $0 <= observedAt }) ?? true else { throw HouseholdFailure.invalid }
            }
        }
    }
    let version: Int
    let observedAt: Int64
    let expectedSessionRevision: Int
    let expectedAssignmentRevision: Int
    let operation: Operation?

    /// A completed cancellation stays visible; a later approved review may start a distinct attempt.
    func allowsReview(_ review: ArrangementReview) -> Bool {
        guard let operation else { return true }
        return operation.state == .cancelled && operation.admission == .open
            && operation.cancellation.map { review.reviewId != operation.reviewId && review.createdAt >= $0.completedAt } == true
    }

    func validate(for session: HouseholdSession, now: Int64, operationId: String? = nil) throws {
        try session.validate()
        guard session.role == "owner", version == 1,
              HouseholdValidation.revision(expectedSessionRevision), HouseholdValidation.revision(expectedAssignmentRevision),
              expectedSessionRevision == session.sessionRevision, expectedAssignmentRevision == session.assignmentRevision,
              ArrangementMaintenanceValidation.fresh(observedAt, now: now) else { throw HouseholdFailure.conflict }
        try operation?.validate(observedAt: observedAt, expectedOperationId: operationId)
    }
    static func decodeExact(_ data: Data) throws -> Self {
        let object = try ArrangementJSON.object(data)
        try ArrangementJSON.keys(object, ["version", "observedAt", "expectedSessionRevision", "expectedAssignmentRevision", "operation"])
        try ArrangementMaintenanceValidation.optionalKeys(object["operation"], fields: Operation.fields)
        if let operation = object["operation"] as? [String: Any] {
            try ArrangementMaintenanceValidation.optionalKeys(operation["restart"], fields: ArrangementRestartReceipt.fields)
            try ArrangementMaintenanceValidation.optionalKeys(operation["recovery"], fields: ArrangementRecoveryReceipt.fields)
            try ArrangementMaintenanceValidation.optionalKeys(operation["cancellation"], fields: ArrangementCancellationReceipt.fields)
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

struct ArrangementCancellationPreview: Codable, Equatable, Sendable {
    let operationId: String
    let expectedSessionRevision: Int
    let expectedAssignmentRevision: Int
    let controlDigest: String
    let observedAt: Int64

    func validate(for session: HouseholdSession, operationId: String, now: Int64, maximumAge: Int64 = 15_000) throws {
        try session.validate()
        guard session.role == "owner", HouseholdValidation.identifier(self.operationId), self.operationId == operationId,
              HouseholdValidation.revision(expectedSessionRevision), HouseholdValidation.revision(expectedAssignmentRevision),
              expectedSessionRevision == session.sessionRevision, expectedAssignmentRevision == session.assignmentRevision,
              ArrangementMaintenanceValidation.digest(controlDigest),
              ArrangementMaintenanceValidation.fresh(observedAt, now: now, maximumAge: maximumAge) else { throw HouseholdFailure.conflict }
    }
    static func decodeExact(_ data: Data) throws -> Self {
        try ArrangementJSON.keys(ArrangementJSON.object(data), ["operationId", "expectedSessionRevision", "expectedAssignmentRevision", "controlDigest", "observedAt"])
        return try JSONDecoder().decode(Self.self, from: data)
    }
}
