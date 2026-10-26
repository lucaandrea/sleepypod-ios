import Foundation

protocol BiometricProfilesServing: Sendable {
    var scope: String { get }
    func overview(side: Side) async throws -> BiometricProfileOverview
    func activationStatus(side: Side, id: String?) async throws -> BiometricActivationStatus
    func history(side: Side, beforeGeneration: Int?) async throws -> BiometricActivationPage
    func profiles(side: Side, cursor: BiometricProfilePage.Cursor?) async throws -> BiometricProfilePage
    func profile(id: String) async throws -> BiometricProfileRevision
    func manifest() async throws -> BiometricProfileManifest
    func resolve(overrides: [BiometricOverride], manifestHash: String) async throws -> BiometricProfileResolution
    func create(_ request: BiometricCandidateRequest) async throws -> BiometricProfileRevision
    func compare(side: Side, revisionId: String?, againstRevisionId: String?) async throws -> BiometricProfileDiff
    func compatibility(side: Side, id: String) async throws -> BiometricProfileCompatibility
    func activate(_ request: BiometricActivationRequest) async throws -> BiometricActivationEvent
}

/// The endpoint is captured once for the workspace, including every retained retry.
struct CoreBiometricProfilesClient: BiometricProfilesServing {
    let transport: CoreRESTClient
    var scope: String { transport.endpoint.absoluteString }
    private let root = "biometric-tuning"
    func overview(side: Side) async throws -> BiometricProfileOverview {
        try await transport.get("\(root)/profiles/overview", query: ["side": side.rawValue])
    }
    func activationStatus(side: Side, id: String?) async throws -> BiometricActivationStatus {
        var query = ["side": side.rawValue]; if let id { query["id"] = id }
        return try await transport.get("\(root)/activation-status", query: query)
    }
    func history(side: Side, beforeGeneration: Int?) async throws -> BiometricActivationPage {
        var query = ["side": side.rawValue]; if let beforeGeneration { query["beforeGeneration"] = String(beforeGeneration) }
        return try await transport.get("\(root)/activations", query: query)
    }
    func profiles(side: Side, cursor: BiometricProfilePage.Cursor?) async throws -> BiometricProfilePage {
        var query = ["side": side.rawValue]
        if let cursor {
            guard cursor.createdAtMs.isFinite, cursor.createdAtMs >= 0, cursor.createdAtMs.rounded() == cursor.createdAtMs else { throw APIError.serverError(message: "Invalid profile page cursor. Reload the newest profiles.") }
            query["beforeCreatedAtMs"] = String(format: "%.0f", cursor.createdAtMs); query["beforeId"] = cursor.id
        }
        return try await transport.get("\(root)/profiles", query: query)
    }
    func profile(id: String) async throws -> BiometricProfileRevision {
        try await transport.get("\(root)/profiles/\(validatedID(id))")
    }
    func manifest() async throws -> BiometricProfileManifest { try await transport.get("\(root)/manifest") }
    func resolve(overrides: [BiometricOverride], manifestHash: String) async throws -> BiometricProfileResolution {
        struct Body: Encodable, Sendable { let overrides: [BiometricOverride]; let baseManifestHash: String }
        return try await transport.post("\(root)/profiles/resolve", body: Body(overrides: overrides, baseManifestHash: manifestHash), returning: BiometricProfileResolution.self)
    }
    func create(_ request: BiometricCandidateRequest) async throws -> BiometricProfileRevision {
        try await transport.post("\(root)/profiles", body: request, returning: BiometricProfileRevision.self)
    }
    func compare(side: Side, revisionId: String?, againstRevisionId: String?) async throws -> BiometricProfileDiff {
        let body = JSONValue.object(["side": .string(side.rawValue), "revisionId": revisionId.map(JSONValue.string) ?? .null, "againstRevisionId": againstRevisionId.map(JSONValue.string) ?? .null])
        return try await transport.post("\(root)/profiles/diff", body: body, returning: BiometricProfileDiff.self)
    }
    func compatibility(side: Side, id: String) async throws -> BiometricProfileCompatibility {
        struct Body: Encodable, Sendable { let side: Side }
        return try await transport.post("\(root)/profiles/\(validatedID(id))/validate", body: Body(side: side), returning: BiometricProfileCompatibility.self)
    }
    func activate(_ request: BiometricActivationRequest) async throws -> BiometricActivationEvent {
        if let id = request.revisionId { _ = try validatedID(id) }
        guard request.action != .activate || request.revisionId != nil else { throw APIError.serverError(message: "Select an exact revision before applying it.") }
        return try await transport.post("\(root)/\(request.action.rawValue)", body: request.body, returning: BiometricActivationEvent.self)
    }
    private func validatedID(_ id: String) throws -> String {
        guard UUID(uuidString: id) != nil else { throw APIError.serverError(message: "Invalid profile identity. Reload the library.") }
        return id
    }
}
