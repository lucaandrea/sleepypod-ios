import Foundation

/// Only the authenticated person's settings are part of this projection.
struct ArrangementReview: Codable, Equatable, Sendable {
    struct Person: Codable, Equatable, Sendable {
        let displayName: String
        let assignmentAtReview: String
        let proposedSide: Side
        let routineSource: String
        let week: [HouseholdRoutine]
        let preferences: HouseholdPreferences
        var approved: Bool
    }
    struct Partner: Codable, Equatable, Sendable {
        let displayName: String
        let proposedSide: Side
        var approved: Bool
    }
    enum State: String, Codable, Sendable {
        case awaitingApproval = "awaiting_approval"
        case approved = "approved_for_separate_activation"
        case stale, expired, cancelled, consumed
        var message: String {
            switch self {
            case .awaitingApproval: "Waiting for each person’s approval."
            case .approved: "Both approvals are saved. The bed has not switched sides."
            case .stale: "Settings or a connection changed. Cancel this review and prepare a fresh one."
            case .expired: "This review expired. Prepare a fresh review when you are both ready."
            case .cancelled: "This review was cancelled. The bed has not changed."
            case .consumed: "A separate activation used this review. Refresh your account to check the current arrangement."
            }
        }
    }
    let version: Int
    let reviewId: String
    let householdId: String
    let podId: String
    let sleeperId: String
    let assignmentRevision: Int
    let createdAt: Int64
    let expiresAt: Int64
    let timeZone: String
    var state: State
    var person: Person
    var partner: Partner
    var canApprove: Bool
    let canActivate: Bool
    let effect: String
    enum CodingKeys: String, CodingKey {
        case version, reviewId, householdId, podId, sleeperId, assignmentRevision, createdAt, expiresAt, timeZone
        case state, partner, canApprove, canActivate, effect
        case person = "self"
    }
    func state(at now: Int64) -> State {
        if [.awaitingApproval, .approved].contains(state), now < createdAt || now >= expiresAt { return .expired }
        return state
    }
    func validate(for session: HouseholdSession) throws {
        guard [reviewId, householdId, podId, sleeperId].allSatisfy(HouseholdValidation.identifier), version == 1,
              HouseholdValidation.revision(assignmentRevision), PersonalControlRequest.validInstant(createdAt),
              PersonalControlRequest.validInstant(expiresAt), expiresAt > createdAt,
              TimeZone(identifier: timeZone) != nil, timeZone.count <= 100,
              !canActivate, effect == "review_only_bed_unchanged",
              HouseholdValidation.name(person.displayName), HouseholdValidation.name(partner.displayName),
              person.proposedSide != partner.proposedSide,
              person.assignmentAtReview == (session.role == "owner" ? "solo" : "unassigned"),
              person.routineSource == (session.role == "owner" ? "preserved_operating_week" : "own_private_draft"),
              !canApprove || (state == .awaitingApproval && !person.approved),
              state != .approved || (person.approved && partner.approved) else { throw HouseholdFailure.invalid }
        guard householdId == session.householdId, podId == session.podId, sleeperId == session.selfSleeperId,
              assignmentRevision == session.assignmentRevision else { throw HouseholdFailure.changedIdentity }
        try person.preferences.validate(); try HouseholdRoutine.validate(person.week)
    }
    static func decodeExact(_ data: Data) throws -> Self {
        let object = try ArrangementJSON.object(data)
        try ArrangementJSON.keys(object, ["version", "reviewId", "householdId", "podId", "sleeperId", "assignmentRevision", "createdAt", "expiresAt", "timeZone", "state", "self", "partner", "canApprove", "canActivate", "effect"])
        try ArrangementJSON.keys(object["self"], ["displayName", "assignmentAtReview", "proposedSide", "routineSource", "week", "preferences", "approved"])
        // Reject accidental partner-private data rather than accepting a broader server response.
        try ArrangementJSON.keys(object["partner"], ["displayName", "proposedSide", "approved"])
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

struct ArrangementIndex: Codable, Sendable {
    let version: Int
    let review: ArrangementReview?
    static func decodeExact(_ data: Data) throws -> Self {
        let object = try ArrangementJSON.object(data)
        try ArrangementJSON.keys(object, ["version", "review"])
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1 else { throw HouseholdFailure.invalid }
        if let review = object["review"], !(review is NSNull) {
            _ = try ArrangementReview.decodeExact(JSONSerialization.data(withJSONObject: review))
        }
        return value
    }
}

enum ArrangementJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HouseholdFailure.invalid }
        return value
    }
    static func keys(_ object: Any?, _ expected: Set<String>) throws {
        guard let object = object as? [String: Any], Set(object.keys) == expected else { throw HouseholdFailure.invalid }
    }
}
