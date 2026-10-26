import Foundation

struct BiometricOverride: Codable, Equatable, Sendable, Identifiable {
    let path: String
    var value: JSONValue
    var id: String { path }
}
struct BiometricProfileRevision: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let familyId: String
    let revision: Int
    let side: Side
    let baseManifestHash: String
    let baseManifest: JSONValue
    let overrides: [BiometricOverride]
    let resolved: JSONValue
    let resolvedHash: String
    let dependencyHashes: [String: String]
    let parentRevisionId: String?
    let origin: String
    let requester: String
    let idempotencyKey: String
    let requestHash: String
    let createdAtMs: Double
}
struct BiometricProfilePage: Decodable, Sendable {
    struct Cursor: Codable, Equatable, Sendable { let createdAtMs: Double; let id: String }
    let items: [BiometricProfileRevision]
    let nextCursor: Cursor?
}
struct BiometricProfileBinding: Codable, Equatable, Sendable {
    let side: Side
    let generation: Int
    let desiredRevisionId: String?
    let previousRevisionId: String?
    let updatedAtMs: Double
}
struct BiometricRuntimeHealth: Codable, Equatable, Sendable {
    struct Component: Codable, Equatable, Sendable, Identifiable {
        let component: String
        let generation: Int?
        let state: String
        let ageMs: Double?
        var id: String { component }
    }
    let state: String
    let staleAfterMs: Double
    let components: [Component]
    /// Age a current report between polls; receipt freshness is independent of successful past adoption.
    func state(after elapsedMilliseconds: Double) -> String {
        guard state == "current" else { return state }
        if components.contains(where: { state($0, after: elapsedMilliseconds) == "stale" }) { return "stale" }
        if components.contains(where: { state($0, after: elapsedMilliseconds) != "current" }) { return "unreported" }
        return "current"
    }
    func state(_ component: Component, after elapsedMilliseconds: Double) -> String {
        guard component.state == "current" else { return component.state }
        guard let age = component.ageMs, age.isFinite, elapsedMilliseconds.isFinite, age >= 0, elapsedMilliseconds >= 0 else { return "unreported" }
        return age + elapsedMilliseconds > staleAfterMs ? "stale" : "current"
    }
}
struct BiometricRuntimeReceipt: Codable, Equatable, Sendable, Identifiable {
    let component: String
    let generation: Int
    let appliedHash: String
    let effectiveSampleTimeMs: Double?
    let state: String
    let error: String?
    let heartbeatAtMs: Double
    var id: String { "\(component)-\(generation)-\(appliedHash)" }
}
struct BiometricStageView: Codable, Equatable, Sendable {
    struct Provenance: Codable, Equatable, Sendable {
        let interpretation: String
        let source: String
        let generation: Int?
        let revisionId: String?
        let bundleHash: String
        let stageHash: String
        let manifestHash: String?
        let effectiveSampleTimeMs: Double?
        let warning: String?
    }
    let classifier: RemoteStageClassifier
    let isDefault: Bool
    let provenance: Provenance
}
struct BiometricProfileOverview: Codable, Equatable, Sendable {
    struct Desired: Codable, Equatable, Sendable {
        let binding: BiometricProfileBinding
        let resolved: JSONValue
        let hash: String
        let isDefault: Bool
        let warning: String?
    }
    struct Legacy: Codable, Equatable, Sendable {
        let classifier: RemoteStageClassifier
        let personalized: Bool
        let migrationPending: Bool
    }
    struct Sensor: Codable, Equatable, Sendable, Identifiable {
        let id: Int
        let sensorType: String
        let status: String
        let qualityScore: Double?
        let createdAtMs: Double
        let expiresAtMs: Double?
        let freshness: String
        let sourceWindowStartMs: Double?
        let sourceWindowEndMs: Double?
    }
    let desired: Desired
    let stageView: BiometricStageView
    let legacyStageView: Legacy
    let runtimeHealth: BiometricRuntimeHealth
    let runtimeStatus: String
    let receipts: [BiometricRuntimeReceipt]
    let sensorCalibration: [Sensor]
    let activationAvailable: Bool
    let limitations: [String]
}
struct BiometricActivationEvent: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let side: Side
    let generation: Int
    let action: String
    let previousRevisionId: String?
    let nextRevisionId: String?
    let previousHash: String
    let nextHash: String
    let evaluationId: String?
    let evidence: JSONValue
    let requester: String
    let state: String
    let reason: String?
    let createdAtMs: Double
    let updatedAtMs: Double
}
struct BiometricActivationStatus: Decodable, Sendable {
    let desiredGeneration: Int
    let isCurrent: Bool
    let event: BiometricActivationEvent?
    let deliveryState: String?
    let observedState: String
    let receiptHealth: BiometricRuntimeHealth
    let receipts: [BiometricRuntimeReceipt]
}
struct BiometricActivationPage: Decodable, Sendable {
    let items: [BiometricActivationEvent]
    let nextGeneration: Int?
}
struct BiometricProfileDiff: Codable, Equatable, Sendable {
    struct Change: Codable, Equatable, Sendable, Identifiable {
        let path: String
        let before: JSONValue
        let after: JSONValue
        var id: String { path }
    }
    let revisionId: String?
    let againstRevisionId: String?
    let beforeHash: String
    let afterHash: String
    let changes: [Change]
    let intentChangedPaths: [String]
}
struct BiometricProfileResolution: Codable, Equatable, Sendable {
    let resolved: JSONValue
    let hash: String
    let manifestHash: String
    let overrides: [BiometricOverride]
    let provenance: [String: String]
}
struct BiometricProfileCompatibility: Decodable, Sendable {
    let id: String
    let resolvedHash: String
    let compatible: Bool
    let evidence: String
    let limitations: [String]
}
struct BiometricProfileManifest: Codable, Sendable {
    let manifestHash: String
    let manifest: JSONValue
    let activationAvailable: Bool

    struct Parameter: Identifiable, Equatable, Sendable {
        let path: String
        let type: String
        let minimum: Double
        let maximum: Double
        let defaultValue: Double
        let unit: String
        let description: String
        var id: String { path }
        var title: String {
            let name = path.components(separatedBy: ".").last ?? path
            let words = name.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression).lowercased()
            return words.prefix(1).uppercased() + words.dropFirst()
        }
        func accepts(_ value: Double) -> Bool {
            value.isFinite && (minimum...maximum).contains(value) && (type != "integer" || value.rounded() == value)
        }
    }
    /// Refuse incomplete/unknown numeric specifications instead of silently omitting an editable parameter.
    func parameters() throws -> [Parameter] {
        var result: [Parameter] = []
        for component in ["heart_rate", "breathing_rate", "hrv_index"] {
            guard case .object(let properties) = manifest["parameters"]?["properties"]?[component]?["properties"], !properties.isEmpty else { throw incompatible }
            for name in properties.keys.sorted() {
                guard let spec = properties[name], let type = spec["type"]?.string, ["number", "integer"].contains(type),
                      let minimum = spec["minimum"]?.number, let maximum = spec["maximum"]?.number, minimum <= maximum,
                      let defaultValue = spec["default"]?.number, let unit = spec["unit"]?.string, let description = spec["description"]?.string else { throw incompatible }
                let parameter = Parameter(path: "\(component).\(name)", type: type, minimum: minimum, maximum: maximum, defaultValue: defaultValue, unit: unit, description: description)
                guard parameter.accepts(defaultValue) else { throw incompatible }
                result.append(parameter)
            }
        }
        return result
    }
    func stageDefaults() throws -> RemoteStageClassifier {
        guard let value = manifest["defaults"]?["sleep_stages"] else { throw incompatible }
        let classifier = try JSONDecoder().decode(RemoteStageClassifier.self, from: JSONEncoder().encode(value))
        guard classifier.validation == nil else { throw incompatible }
        return classifier
    }
    private var incompatible: APIError { .serverError(message: "The parameter definitions are incompatible with this editor. Reload after updating the app or controller.") }
}
enum BiometricProfileAction: String, Codable, Sendable {
    case activate, reset, rollback
    var title: String {
        switch self {
        case .activate: "Apply unvalidated revision"
        case .reset: "Restore system defaults"
        case .rollback: "Restore previous profile"
        }
    }
}
enum BiometricProfileBoundary: String, Codable, CaseIterable, Sendable {
    case nextSession = "next_session", immediate
    var title: String { self == .nextSession ? "Next session boundary" : "Immediate processing boundary" }
}
struct BiometricActivationRequest: Codable, Equatable, Sendable {
    let action: BiometricProfileAction
    let side: Side
    let revisionId: String?
    let expectedGeneration: Int
    let expectedResolvedHash: String
    let boundary: BiometricProfileBoundary
    let requester: String
    let idempotencyKey: String
    let allowUnvalidated: Bool

    /// REST reset omits revisionId; rollback to defaults must send explicit null.
    var body: JSONValue {
        var fields: [String: JSONValue] = [
            "side": .string(side.rawValue), "expectedGeneration": .number(Double(expectedGeneration)),
            "expectedResolvedHash": .string(expectedResolvedHash), "boundary": .string(boundary.rawValue),
            "requester": .string(requester), "idempotencyKey": .string(idempotencyKey), "allowUnvalidated": .bool(allowUnvalidated)
        ]
        if action != .reset { fields["revisionId"] = revisionId.map(JSONValue.string) ?? .null }
        return .object(fields)
    }
}
struct BiometricCandidateRequest: Codable, Equatable, Sendable {
    let side: Side
    let parentRevisionId: String?
    let baseManifestHash: String
    let overrides: [BiometricOverride]
    let origin: String
    let requester: String
    let idempotencyKey: String
}
enum BiometricProfileLabels {
    static func state(_ state: String) -> String {
        switch state {
        case "unreported": "Not reported"
        case "current": "Current"
        case "stale": "Stale"
        case "failed": "Failed"
        case "mixed_generations": "Different versions reported"
        case "clock_skew": "Clock mismatch"
        case "pending_delivery": "Waiting for delivery"
        case "pending_boundary": "Waiting for a processing boundary"
        case "applied": "Applied"
        case "saved": "Saved"
        default: state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    static func component(_ value: String) -> String {
        switch value {
        case "heart_rate": "Heart rate"
        case "breathing_rate": "Breathing rate"
        case "hrv_index": "HRV index"
        case "sleep_stages": "Sleep stages"
        default: value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
