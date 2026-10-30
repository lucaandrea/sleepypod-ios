import Foundation

struct ArrangementRequest: Codable, Equatable, Sendable {
    enum Action: String, Sendable { case propose, approve, cancel }
    let version: Int
    let requestId: String
    let expectedSessionRevision: Int
    let expectedAssignmentRevision: Int
    let ownerSide: Side?
    let confirmPreserveOperatingOwnerWeek: Bool?
    let reviewId: String?
    let issuedAt: Int64?
    let expiresAt: Int64?
    let confirmMySide: Bool?
    let confirmMyRoutine: Bool?
    let acknowledgeSeparateActivation: Bool?

    init(action: Action, session: HouseholdSession, reviewId: String? = nil, ownerSide: Side = .right, now: Int64) {
        version = 1; requestId = UUID().uuidString.lowercased()
        expectedSessionRevision = session.sessionRevision; expectedAssignmentRevision = session.assignmentRevision
        self.ownerSide = action == .propose ? ownerSide : nil
        confirmPreserveOperatingOwnerWeek = action == .propose ? true : nil
        self.reviewId = action == .propose ? nil : reviewId
        issuedAt = action == .approve ? now : nil; expiresAt = action == .approve ? now + 30_000 : nil
        confirmMySide = action == .approve ? true : nil; confirmMyRoutine = action == .approve ? true : nil
        acknowledgeSeparateActivation = action == .approve ? true : nil
    }
    static func decodeExact(_ data: Data, action: Action, session: HouseholdSession) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        var fields: Set<String> = ["version", "requestId", "expectedSessionRevision", "expectedAssignmentRevision"]
        switch action {
        case .propose: fields.formUnion(["ownerSide", "confirmPreserveOperatingOwnerWeek"])
        case .approve: fields.formUnion(["reviewId", "issuedAt", "expiresAt", "confirmMySide", "confirmMyRoutine", "acknowledgeSeparateActivation"])
        case .cancel: fields.insert("reviewId")
        }
        try ArrangementJSON.keys(ArrangementJSON.object(data), fields)
        guard value.version == 1, HouseholdValidation.identifier(value.requestId),
              HouseholdValidation.revision(value.expectedSessionRevision), HouseholdValidation.revision(value.expectedAssignmentRevision),
              value.expectedSessionRevision == session.sessionRevision, value.expectedAssignmentRevision == session.assignmentRevision else { throw HouseholdFailure.changedIdentity }
        if action == .propose {
            guard session.role == "owner", value.ownerSide != nil, value.confirmPreserveOperatingOwnerWeek == true else { throw HouseholdFailure.forbidden }
        } else {
            guard let reviewId = value.reviewId, HouseholdValidation.identifier(reviewId) else { throw HouseholdFailure.invalid }
        }
        if action == .approve {
            guard let issuedAt = value.issuedAt, let expiresAt = value.expiresAt,
                  PersonalControlRequest.validInstant(issuedAt), PersonalControlRequest.validInstant(expiresAt),
                  expiresAt > issuedAt, expiresAt - issuedAt <= 60_000,
                  value.confirmMySide == true, value.confirmMyRoutine == true, value.acknowledgeSeparateActivation == true else { throw HouseholdFailure.invalid }
        }
        return value
    }
}
