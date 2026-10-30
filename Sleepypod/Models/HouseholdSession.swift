import Foundation

enum HouseholdFailure: Error, LocalizedError, Equatable {
    case invalid, changedIdentity, authentication, conflict, unavailable, invitation, forbidden, rateLimited, uncertain, storage, preparationOnly
    var errorDescription: String? {
        switch self {
        case .invalid: "The personal-account response could not be verified. Refresh before continuing."
        case .changedIdentity: "The account or assignment changed. Your previous account's data has been hidden. Reconnect before continuing."
        case .authentication: "This personal connection is unavailable or has been revoked. Join with a new device invitation."
        case .conflict: "Your account or saved draft changed. Refresh and review before saving again."
        case .unavailable: "Personal-account preparation is not available on this controller yet."
        case .invitation: "This invitation is expired, revoked or already claimed. Ask for a new invitation."
        case .forbidden: "This action is not available to your personal account."
        case .rateLimited: "Too many requests or pending invitations. Wait before trying again."
        case .uncertain: "The result is unknown. Your original request and connection secret are kept securely. Check the saved state before retrying."
        case .preparationOnly: "This controller reports an active personal routine. Update the app before editing it; this workspace supports drafts only."
        case .storage: "Secure storage is unavailable. Unlock this device and refresh; a request already sent may still need confirmation."
        }
    }
}

struct HouseholdSession: Codable, Equatable, Sendable {
    struct Arrangement: Codable, Equatable, Sendable { let mode: String; let effectiveAt: String }
    struct Person: Codable, Equatable, Sendable { let displayName: String; let zones: [Side]; let assignment: String }
    struct Capabilities: Codable, Equatable, Sendable {
        let manageInvitations: Bool
        let manageOwnDevices: Bool
        let personalPreferences: Bool
        let personalRoutineDrafts: Bool
        var personalRoutinePublication: Bool?
        var arrangementReview: Bool?
        let activateArrangement: Bool
        let personalControls: Bool
        let personalHistory: Bool
        let healthImport: Bool
        let cloudAnalysis: Bool
    }
    let apiVersion: Int
    let featureVersion: Int
    let podId: String
    let householdId: String
    let accountId: String
    let selfSleeperId: String
    let role: String
    let membership: String
    let sessionRevision: Int
    let householdRevision: Int
    let assignmentRevision: Int
    let arrangement: Arrangement
    let person: Person
    let capabilities: Capabilities
    enum CodingKeys: String, CodingKey {
        case apiVersion, featureVersion, podId, householdId, accountId, selfSleeperId, role, membership
        case sessionRevision, householdRevision, assignmentRevision, arrangement, capabilities
        case person = "self"
    }
    var identity: [String] { [podId, householdId, accountId, selfSleeperId] }
    var context: [String] { identity + [String(sessionRevision), String(assignmentRevision)] }
    var namespace: String { identity.joined(separator: "/") }
    var assignmentLabel: String {
        switch person.assignment {
        case "solo": "Only sleeper · either side"
        case "left": "Left side"
        case "right": "Right side"
        default: "No bed side assigned"
        }
    }
    func validate() throws {
        guard apiVersion == 1, featureVersion == 1, identity.allSatisfy(HouseholdValidation.identifier),
              [sessionRevision, householdRevision, assignmentRevision].allSatisfy(HouseholdValidation.revision),
              ["owner", "member"].contains(role), membership == "active", HouseholdValidation.name(person.displayName),
              ["solo-anywhere", "assigned"].contains(arrangement.mode), SensorObservation.date(arrangement.effectiveAt) != nil,
              Set(person.zones).count == person.zones.count, person.zones.count <= 2,
              ["solo", "left", "right", "unassigned"].contains(person.assignment),
              capabilities.manageOwnDevices, capabilities.personalPreferences, capabilities.personalRoutineDrafts,
              !capabilities.cloudAnalysis else { throw HouseholdFailure.invalid }
        let expected: Set<Side> = switch person.assignment {
        case "solo": [.left, .right]
        case "left": [.left]
        case "right": [.right]
        default: []
        }
        guard Set(person.zones) == expected,
              role == "owner" || !capabilities.manageInvitations else { throw HouseholdFailure.invalid }
    }
}

enum HouseholdValidation {
    static func identifier(_ value: String) -> Bool { UUID(uuidString: value) != nil }
    static func revision(_ value: Int) -> Bool { value > 0 && value <= 9_007_199_254_740_991 }
    static func name(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf16.count <= 80 }
    static func secret(_ value: String) -> Bool { value.range(of: #"^[A-Za-z0-9_-]{43,128}$"#, options: .regularExpression) != nil }
}
