import Foundation

struct PersonalControlAction: Codable, Equatable, Sendable {
    let kind: String
    var temperatureF: Int?
    var holdMinutes: Int?
    var powered: Bool?
    init(kind: String, temperatureF: Int? = nil, holdMinutes: Int? = nil, powered: Bool? = nil) {
        self.kind = kind; self.temperatureF = temperatureF; self.holdMinutes = holdMinutes; self.powered = powered
    }
    private enum Field: String, CodingKey { case kind, temperatureF, holdMinutes, powered }
    private struct AnyField: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: AnyField.self).allKeys.map(\.stringValue)
        let values = try decoder.container(keyedBy: Field.self)
        kind = try values.decode(String.self, forKey: .kind)
        for field in [Field.temperatureF, .holdMinutes, .powered] where values.contains(field) {
            guard try !values.decodeNil(forKey: field) else { throw HouseholdFailure.invalid }
        }
        temperatureF = try values.decodeIfPresent(Int.self, forKey: .temperatureF)
        holdMinutes = try values.decodeIfPresent(Int.self, forKey: .holdMinutes)
        powered = try values.decodeIfPresent(Bool.self, forKey: .powered)
        let permitted: Set<String> = switch kind {
        case "temperature": ["kind", "temperatureF", "holdMinutes"]
        case "power": ["kind", "temperatureF", "powered"]
        default: ["kind"]
        }
        guard Set(keys).isSubset(of: permitted) else { throw HouseholdFailure.invalid }
        try validate()
    }
    var isStopping: Bool { kind == "vibration.clear" || (kind == "power" && powered == false) }
    var label: String {
        switch kind {
        case "temperature": "Temperature \(temperatureF ?? 0)°F"
        case "power": powered == true ? "Power on" : "Power off"
        default: "Stop vibration"
        }
    }
    func validate() throws {
        switch kind {
        case "temperature":
            guard let temperatureF, (55...110).contains(temperatureF), let holdMinutes, (1...1440).contains(holdMinutes), powered == nil else { throw HouseholdFailure.invalid }
        case "power":
            guard powered != nil, holdMinutes == nil, temperatureF.map({ (55...110).contains($0) }) ?? true else { throw HouseholdFailure.invalid }
        case "vibration.clear":
            guard temperatureF == nil, holdMinutes == nil, powered == nil else { throw HouseholdFailure.invalid }
        default: throw HouseholdFailure.invalid
        }
    }
}

struct PersonalControlRequest: Codable, Equatable, Sendable {
    let version: Int
    let requestId: UUID
    let scope: PersonalControlScope
    let issuedAt: Int64
    let expiresAt: Int64
    let action: PersonalControlAction
    init(scope: PersonalControlScope, action: PersonalControlAction, now: Date, requestId: UUID = UUID()) throws {
        let instant = now.timeIntervalSince1970 * 1_000
        guard instant.isFinite, instant > 0, instant < 8_640_000_000_000_000 - 60_000 else { throw HouseholdFailure.invalid }
        version = 1; self.requestId = requestId; self.scope = scope; self.action = action
        issuedAt = Int64(instant); expiresAt = issuedAt + 30_000
        try validate()
    }
    enum CodingKeys: String, CodingKey { case version, requestId, scope, issuedAt, expiresAt, action }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version); try values.encode(requestId.uuidString.lowercased(), forKey: .requestId)
        try values.encode(scope, forKey: .scope); try values.encode(action, forKey: .action)
        try values.encode(issuedAt, forKey: .issuedAt); try values.encode(expiresAt, forKey: .expiresAt)
    }
    static func validInstant(_ value: Int64) -> Bool { value > 0 && value <= 8_640_000_000_000_000 }
    func validate() throws {
        try scope.validate(); try action.validate()
        guard version == 1, Self.validInstant(issuedAt), Self.validInstant(expiresAt), expiresAt > issuedAt,
              expiresAt - issuedAt <= 60_000 else { throw HouseholdFailure.invalid }
    }
}

struct PersonalControlReceipt: Codable, Equatable, Sendable {
    let version: Int
    let requestId: UUID
    let scope: PersonalControlScope
    let action: PersonalControlAction
    let issuedAt: Int64
    let expiresAt: Int64
    let receivedAt: Int64
    let finishedAt: Int64?
    let lastDispatchAt: Int64?
    let state: String
    let reason: String?
    let dispatchCount: Int
    let physicalVerification: String
    let replayAllowed: Bool
    let resolvedZones: [Side]
    var uncertain: Bool { state == "unknown" || state == "executing" }
    var message: String {
        switch state {
        case "acknowledged": "Controller acknowledged. Check the bed to confirm its physical response."
        case "not_dispatched": "No hardware write was made."
        case "expired", "rejected": "The command was refused before a hardware write."
        case "executing": "Awaiting the controller’s outcome. Checking the receipt will not resend the command."
        default: "Outcome unknown. Check the bed and review the receipt before another adjustment."
        }
    }
    func validate(for attempt: PersonalControlAttempt) throws {
        let request = attempt.request
        try request.validate(); try validate()
        guard requestId == request.requestId, scope == request.scope, action == request.action,
              issuedAt == request.issuedAt, expiresAt == request.expiresAt,
              Set(resolvedZones) == Set(attempt.authorizedZones) else { throw HouseholdFailure.invalid }
    }
    func validate() throws {
        try scope.validate(); try action.validate()
        guard version == 1, PersonalControlRequest.validInstant(issuedAt), PersonalControlRequest.validInstant(expiresAt),
              expiresAt > issuedAt, expiresAt - issuedAt <= 60_000, PersonalControlRequest.validInstant(receivedAt),
              finishedAt.map(PersonalControlRequest.validInstant) ?? true, lastDispatchAt.map(PersonalControlRequest.validInstant) ?? true,
              finishedAt.map({ $0 >= receivedAt }) ?? true, dispatchCount >= 0,
              ["executing", "acknowledged", "not_dispatched", "rejected", "expired", "unknown"].contains(state),
              physicalVerification == "unverified", !replayAllowed,
              Set(resolvedZones).count == resolvedZones.count, !resolvedZones.isEmpty, resolvedZones.count <= 2,
              state != "acknowledged" || (dispatchCount > 0 && finishedAt != nil && lastDispatchAt != nil),
              state != "executing" || finishedAt == nil,
              !["not_dispatched", "rejected", "expired"].contains(state) || (dispatchCount == 0 && lastDispatchAt == nil) else { throw HouseholdFailure.invalid }
    }
}

struct PersonalControlAttempt: Codable, Equatable, Identifiable, Sendable {
    let request: PersonalControlRequest
    let body: Data
    let authorizedZones: [Side]
    var receipt: PersonalControlReceipt?
    var reviewedAt: Date?
    var id: UUID { request.requestId }
    var needsReview: Bool { reviewedAt == nil && (receipt?.uncertain ?? true) }
    func validate() throws {
        try request.validate()
        guard try JSONDecoder().decode(PersonalControlRequest.self, from: body) == request,
              !authorizedZones.isEmpty, authorizedZones.count <= 2, Set(authorizedZones).count == authorizedZones.count else { throw HouseholdFailure.invalid }
        try receipt?.validate(for: self)
    }
}

/// Revocation retains no credential or command contents, only enough to find an own-account receipt.
struct PersonalControlTombstone: Codable, Equatable, Identifiable, Sendable {
    static let capacity = 64
    let identity: [String]
    let requestId: UUID
    let expiresAt: Int64
    var unresolvedState: String
    var id: UUID { requestId }
    func validate() throws {
        guard identity.count == 4, identity.allSatisfy(HouseholdValidation.identifier),
              PersonalControlRequest.validInstant(expiresAt),
              ["awaiting", "executing", "unknown"].contains(unresolvedState) else { throw HouseholdFailure.invalid }
    }
    func matches(_ session: HouseholdSession) -> Bool { identity == session.identity }
    func validate(_ receipt: PersonalControlReceipt, session: HouseholdSession) throws {
        try validate(); try receipt.validate()
        guard matches(session), receipt.requestId == requestId, receipt.expiresAt == expiresAt,
              receipt.scope.belongs(to: session) else { throw HouseholdFailure.changedIdentity }
    }
}
