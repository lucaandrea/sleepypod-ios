import Foundation

enum NativeControlFailure: LocalizedError {
    case invalid, unavailable, changedOwner, unresolved
    var errorDescription: String? {
        switch self {
        case .invalid: "The controller's command receipt could not be verified. Open command history before trying again."
        case .unavailable: "Update your controller to use commands with delivery receipts."
        case .changedOwner: "Your Pod connection changed. Review the selected controller before issuing a command."
        case .unresolved: "An earlier command has an uncertain result. Open command history to refresh and review it before another command. Stop remains available."
        }
    }
}

struct NativeControlAction: Codable, Equatable, Sendable {
    let kind: String
    var side: Side?
    var temperature: Int?
    var holdMinutes: Int?
    var powered: Bool?
    var intensity: Int?
    var pattern: String?
    var duration: Int?
    var head: Int?
    var feet: Int?
    var feedRate: Int?

    var family: String { kind.hasPrefix("base.") ? "base" : "\(side?.rawValue ?? "")-\(kind.hasPrefix("vibration") ? "vibration" : "thermal")" }
    var isStopping: Bool { kind == "base.stop" || kind == "vibration.clear" || (kind == "power" && powered == false) }
    var label: String {
        switch kind {
        case "temperature": "\(side?.displayName ?? "") temperature \(temperature ?? 0)°F"
        case "power": "\(side?.displayName ?? "") power \(powered == true ? "on" : "off")"
        case "vibration": "\(side?.displayName ?? "") vibration"
        case "vibration.clear": "Dismiss \(side?.displayName.lowercased() ?? "") vibration"
        case "base.position": "Base: head \(head ?? 0)°, feet \(feet ?? 0)°"
        default: "Stop base movement"
        }
    }
    /// Only fields accepted by the strict Core action schema may cross the fixed endpoint.
    func validate() throws {
        let data = try JSONEncoder().encode(self)
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NativeControlFailure.invalid }
        let required: Set<String>, optional: Set<String>
        switch kind {
        case "temperature":
            required = ["kind", "side", "temperature"]; optional = ["holdMinutes"]
            guard let temperature, (55...110).contains(temperature), holdMinutes.map({ (1...1440).contains($0) }) ?? true else { throw NativeControlFailure.invalid }
        case "power":
            required = ["kind", "side", "powered"]; optional = ["temperature"]
            guard powered != nil, temperature.map({ (55...110).contains($0) }) ?? true else { throw NativeControlFailure.invalid }
        case "vibration":
            required = ["kind", "side", "intensity", "pattern", "duration"]; optional = []
            guard let intensity, (1...100).contains(intensity), let pattern, ["rise", "double"].contains(pattern),
                  let duration, (10...180).contains(duration) else { throw NativeControlFailure.invalid }
        case "vibration.clear": required = ["kind", "side"]; optional = []
        case "base.position":
            required = ["kind", "head", "feet", "feedRate"]; optional = []
            guard let head, (0...60).contains(head), let feet, (0...45).contains(feet), let feedRate, (30...100).contains(feedRate) else { throw NativeControlFailure.invalid }
        case "base.stop": required = ["kind"]; optional = []
        default: throw NativeControlFailure.invalid
        }
        let keys = Set(fields.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else { throw NativeControlFailure.invalid }
    }
}

struct NativeControlRequest: Codable, Equatable, Sendable {
    let requestId: UUID
    let issuedAt: Int64
    let expiresAt: Int64
    let action: NativeControlAction
    init(action: NativeControlAction, now: Date = .now, requestId: UUID = UUID()) throws {
        try action.validate()
        let milliseconds = now.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite, milliseconds > 0, milliseconds < 8_640_000_000_000_000 - 60_000 else { throw NativeControlFailure.invalid }
        self.requestId = requestId; issuedAt = Int64(milliseconds); expiresAt = issuedAt + 30_000; self.action = action
    }
    enum CodingKeys: String, CodingKey { case requestId, issuedAt, expiresAt, action }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        // Core stores the literal UUID text; use the same lowercase spelling in POST and GET.
        try values.encode(requestId.uuidString.lowercased(), forKey: .requestId)
        try values.encode(issuedAt, forKey: .issuedAt); try values.encode(expiresAt, forKey: .expiresAt)
        try values.encode(action, forKey: .action)
    }
    func validate() throws {
        try action.validate()
        guard issuedAt > 0, expiresAt > issuedAt, expiresAt <= 8_640_000_000_000_000,
              expiresAt - issuedAt <= 60_000 else { throw NativeControlFailure.invalid }
    }
}

struct NativeControlReceipt: Codable, Equatable, Sendable {
    let version: Int
    let requestId: UUID
    let action: NativeControlAction
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
    var uncertain: Bool { state == "unknown" || state == "executing" }
    var message: String {
        switch state {
        case "acknowledged": "The controller acknowledged the command. Physical movement or temperature change has not been verified."
        case "not_dispatched": "The controller made no hardware write."
        case "rejected": "The controller rejected this command before dispatch."
        case "expired": "This command expired before dispatch."
        case "executing": "The controller is still processing this command. Refresh its receipt; it will not be resent."
        default: "The command outcome is unknown. Check the bed and review this receipt before another command."
        }
    }
    func validate(for request: NativeControlRequest) throws {
        try request.validate()
        guard version == 1, requestId == request.requestId, action == request.action,
              issuedAt == request.issuedAt, expiresAt == request.expiresAt, receivedAt > 0,
              ["executing", "acknowledged", "not_dispatched", "rejected", "expired", "unknown"].contains(state),
              physicalVerification == "unverified", !replayAllowed, dispatchCount >= 0,
              finishedAt.map({ $0 >= receivedAt }) ?? true, lastDispatchAt.map({ $0 > 0 }) ?? true,
              state != "acknowledged" || dispatchCount > 0 else { throw NativeControlFailure.invalid }
        try action.validate()
    }
}

struct NativeControlAttempt: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { request.requestId }
    let request: NativeControlRequest
    var receipt: NativeControlReceipt?
    var reviewedAt: Date?
    var needsReview: Bool { reviewedAt == nil && (receipt?.uncertain ?? true) }
}
