#if DEBUG
import Foundation
import FreeSleepKit

/// Synthetic UI fixtures use an in-memory vault and actor; they never create an HTTP transport.
@MainActor enum PersonalTemperaturePreview {
    static func make() -> HouseholdWorkspace? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--personal-temp-fixture"), arguments.indices.contains(index + 1) else { return nil }
        do {
            let mode = arguments[index + 1]
            let bedKey = mode == "solo" ? "soloBed" : mode == "disabled" ? "disabledBed" : mode == "unassigned" ? "unassignedBed" : "assignedBed"
            let bed = try JSONDecoder().decode(PersonalBed.self, from: fixture("personal-controls-v1", key: bedKey))
            var sessionObject = try object(fixture("household-preparation-v1", key: "ownerSession"))
            sessionObject["selfSleeperId"] = bed.scope.sleeperId
            sessionObject["assignmentRevision"] = bed.scope.assignmentRevision
            sessionObject["arrangement"] = ["mode": bed.arrangement, "effectiveAt": "2026-10-29T20:00:00Z"]
            let zones = mode == "unassigned" ? [] : bed.arrangement == "solo-anywhere" ? ["left", "right"] : ["left"]
            sessionObject["self"] = ["displayName": "Preview sleeper", "zones": zones, "assignment": zones.isEmpty ? "unassigned" : zones.count == 2 ? "solo" : "left"]
            var capabilities = sessionObject["capabilities"] as? [String: Any] ?? [:]
            capabilities["personalControls"] = mode != "disabled" && mode != "unassigned"
            sessionObject["capabilities"] = capabilities
            let session = try JSONDecoder().decode(HouseholdSession.self, from: JSONSerialization.data(withJSONObject: sessionObject))
            let record = HouseholdConnectionRecord(id: UUID(), endpoint: URL(string: "https://preview.invalid")!, deviceSecret: String(repeating: "A", count: 43), identity: session)
            let vault = PersonalTemperaturePreviewVault(state: .init(connections: [record], selected: record.id))
            let defaults = UserDefaults(suiteName: "personal-temperature-preview")!
            defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
            let server = PersonalTemperaturePreviewServer(session: session, snapshot: bed, unknown: mode == "unknown")
            return HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in server }, personalClient: { _ in server },
                                      capability: { false }, ownerEndpoint: { nil }, ownerKey: { _ in "" })
        } catch { return nil }
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HouseholdFailure.invalid }
        return object
    }
    private static func fixture(_ file: String, key: String) throws -> Data {
        guard let url = Bundle.main.url(forResource: file, withExtension: "json"), let value = try object(Data(contentsOf: url))[key] else { throw HouseholdFailure.invalid }
        return try JSONSerialization.data(withJSONObject: value)
    }
}

@MainActor private final class PersonalTemperaturePreviewVault: HouseholdVault {
    var state: HouseholdVaultState
    init(state: HouseholdVaultState) { self.state = state }
    func load() throws -> HouseholdVaultState { state }
    func save(_ state: HouseholdVaultState) throws { self.state = state }
}

private actor PersonalTemperaturePreviewServer: HouseholdTransport, PersonalBedTransport {
    let account: HouseholdSession
    var snapshot: PersonalBed
    let unknown: Bool
    var receipts: [UUID: PersonalControlReceipt] = [:]
    init(session: HouseholdSession, snapshot: PersonalBed, unknown: Bool) { account = session; self.snapshot = snapshot; self.unknown = unknown }
    func session() async throws -> HouseholdSession { account }
    func bed() async throws -> PersonalBed {
        .init(version: snapshot.version, scope: snapshot.scope, arrangement: snapshot.arrangement, availability: snapshot.availability,
              routing: snapshot.routing, observation: .init(state: snapshot.observation.state,
                observedAt: snapshot.observation.state == "fresh" ? Int64(Date().timeIntervalSince1970 * 1_000) : nil,
                water: snapshot.observation.water, priming: snapshot.observation.priming), zones: snapshot.zones, physicalVerification: "unverified")
    }
    func submit(_ body: Data) async throws -> PersonalControlReceipt {
        let request = try JSONDecoder().decode(PersonalControlRequest.self, from: body)
        try request.validate()
        guard request.scope == snapshot.scope else { throw HouseholdFailure.changedIdentity }
        let receipt = PersonalControlReceipt(version: 1, requestId: request.requestId, scope: request.scope, action: request.action,
            issuedAt: request.issuedAt, expiresAt: request.expiresAt, receivedAt: request.issuedAt,
            finishedAt: request.issuedAt + 200, lastDispatchAt: request.issuedAt + 100, state: unknown ? "unknown" : "acknowledged",
            reason: unknown ? "dispatch_outcome_unknown" : nil, dispatchCount: unknown ? 1 : snapshot.zones.count,
            physicalVerification: "unverified", replayAllowed: false, resolvedZones: snapshot.routing.zones(for: request.action))
        receipts[request.requestId] = receipt
        return receipt
    }
    func receipt(_ requestId: UUID) async throws -> PersonalControlReceipt {
        guard let receipt = receipts[requestId] else { throw PersonalControlFailure.missingReceipt }; return receipt
    }
    func send(path: String, method: String, token: String?, body: Data?) async throws -> Data {
        guard method == "GET" else { throw HouseholdFailure.unavailable }
        switch path {
        case "household/session": return try JSONEncoder().encode(account)
        case "me/preferences": return try JSONEncoder().encode(HouseholdPreferencesResponse(sleeperId: account.selfSleeperId, revision: 1, preferences: .blank))
        case "me/routines": return try JSONEncoder().encode(HouseholdRoutinesResponse(sleeperId: account.selfSleeperId, revision: 1, status: "draft_only", routines: []))
        case "household/devices": return Data(#"{"devices":[{"id":"00000000-0000-4000-8000-000000000008","name":"Preview phone","createdAt":"2026-10-29T20:00:00Z","current":true}]}"#.utf8)
        case "household/invitations": return Data(#"{"invitations":[]}"#.utf8)
        default: throw HouseholdFailure.unavailable
        }
    }
}
#endif
