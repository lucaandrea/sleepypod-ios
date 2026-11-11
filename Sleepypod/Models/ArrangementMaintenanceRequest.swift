import Foundation

/// One explicit request, never a retryable control intent. Each action has a distinct confirmation set.
struct ArrangementMaintenanceRequest: Sendable {
    enum Action: String, Sendable {
        case activate, restart, recover, cancel
        var path: String { "household/transition" + (self == .activate ? "" : "/\(rawValue)") }
        var referenceField: String { self == .activate ? "reviewId" : "operationId" }
        var confirmations: Set<String> {
            switch self {
            case .activate: ["confirmEmptyAndAttended", "confirmClearTemporaryActions", "confirmPauseLearningAndSharedAutomations", "acknowledgeHeldUntilRecovery"]
            case .restart: ["confirmEmptyAndAttended", "acknowledgeConnectionWillClose", "acknowledgeControlsRemainPaused"]
            case .recover: ["confirmEmptyAndAttended", "confirmAssignedSides", "acknowledgeRecordingGap", "acknowledgeLearningRemainsOff"]
            case .cancel: ["confirmEmptyAndAttended", "confirmKeepSoloArrangement", "acknowledgeSavedRoutinesMayResume"]
            }
        }
    }
    private struct Context: Decodable {
        let version: Int
        let requestId: String
        let expectedSessionRevision: Int
        let expectedAssignmentRevision: Int
        let issuedAt: Int64
        let expiresAt: Int64
    }
    let action: Action
    let requestId: String
    let referenceId: String
    let body: Data

    init(action: Action, session: HouseholdSession, referenceId: String, confirmations: Set<String>, now: Int64, controlDigest: String? = nil) throws {
        guard confirmations == action.confirmations, PersonalControlRequest.validInstant(now), now <= 8_640_000_000_000_000 - 60_000 else { throw HouseholdFailure.invalid }
        var object: [String: Any] = ["version": 1, "requestId": UUID().uuidString.lowercased(),
            "expectedSessionRevision": session.sessionRevision, "expectedAssignmentRevision": session.assignmentRevision,
            "issuedAt": now, "expiresAt": now + 60_000, action.referenceField: referenceId]
        for field in confirmations { object[field] = true }
        if let controlDigest { object["expectedControlDigest"] = controlDigest }
        self = try Self.decodeExact(JSONSerialization.data(withJSONObject: object), action: action, session: session, now: now)
    }

    private init(action: Action, requestId: String, referenceId: String, body: Data) {
        self.action = action; self.requestId = requestId; self.referenceId = referenceId; self.body = body
    }
    static func decodeExact(_ data: Data, action: Action, session: HouseholdSession, now: Int64) throws -> Self {
        try session.validate()
        guard session.role == "owner", session.capabilities.arrangementMaintenance == true,
              action != .activate || session.capabilities.activateArrangement else { throw HouseholdFailure.forbidden }
        let object = try ArrangementJSON.object(data)
        var fields: Set<String> = ["version", "requestId", "expectedSessionRevision", "expectedAssignmentRevision", "issuedAt", "expiresAt", action.referenceField]
        fields.formUnion(action.confirmations)
        if action == .cancel { fields.insert("expectedControlDigest") }
        try ArrangementJSON.keys(object, fields)
        let context = try JSONDecoder().decode(Context.self, from: data)
        guard context.version == 1, HouseholdValidation.identifier(context.requestId),
              context.expectedSessionRevision == session.sessionRevision, context.expectedAssignmentRevision == session.assignmentRevision,
              [context.issuedAt, context.expiresAt, now].allSatisfy(PersonalControlRequest.validInstant),
              context.issuedAt <= now, context.expiresAt > now, context.expiresAt > context.issuedAt,
              context.expiresAt - context.issuedAt <= 60_000,
              let referenceId = object[action.referenceField] as? String, HouseholdValidation.identifier(referenceId) else { throw HouseholdFailure.conflict }
        // Decode individual flags as Bool; numeric 1 must not masquerade as consent.
        for field in action.confirmations {
            guard let value = object[field], try JSONDecoder().decode(Bool.self, from: JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)) else { throw HouseholdFailure.invalid }
        }
        if action == .cancel {
            guard let digest = object["expectedControlDigest"] as? String, ArrangementMaintenanceValidation.digest(digest) else { throw HouseholdFailure.invalid }
        }
        return .init(action: action, requestId: context.requestId, referenceId: referenceId, body: data)
    }
}
