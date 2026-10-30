#if DEBUG
import Foundation
import CryptoKit
import FreeSleepKit

/// Synthetic publication UI scenarios have no HTTP client or live owner connection.
@MainActor enum PersonalRoutinePreview {
    static func make() -> HouseholdWorkspace? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--personal-routine-fixture"), arguments.indices.contains(index + 1) else { return nil }
        do {
            let mode = arguments[index + 1]
            let snapshot = try JSONDecoder().decode(PersonalRoutineReview.self, from: fixture("personal-routines-v1", key: mode == "untouched" ? "untouchedReview" : "readyReview"))
            var object = try dictionary(fixture("household-preparation-v1", key: "ownerSession"))
            object["podId"] = snapshot.scope.podId; object["householdId"] = snapshot.scope.householdId
            object["selfSleeperId"] = snapshot.scope.sleeperId; object["sessionRevision"] = snapshot.scope.sessionRevision
            object["assignmentRevision"] = snapshot.scope.assignmentRevision
            object["arrangement"] = ["mode": "solo-anywhere", "effectiveAt": "2026-10-29T20:00:00Z"]
            object["self"] = ["displayName": "Preview sleeper", "zones": ["left", "right"], "assignment": "solo"]
            var capabilities = object["capabilities"] as? [String: Any] ?? [:]
            capabilities["personalControls"] = false; capabilities["personalRoutinePublication"] = mode != "disabled"; object["capabilities"] = capabilities
            let session = try JSONDecoder().decode(HouseholdSession.self, from: JSONSerialization.data(withJSONObject: object))
            let record = HouseholdConnectionRecord(id: UUID(), endpoint: URL(string: "https://publication-preview.invalid")!, deviceSecret: String(repeating: "A", count: 43), identity: session)
            let vault = PersonalRoutinePreviewVault(state: .init(connections: [record], selected: record.id))
            let defaults = UserDefaults(suiteName: "personal-routine-preview")!
            defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
            let server = PersonalRoutinePreviewServer(account: session, review: snapshot, mode: mode)
            return HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in server }, routineClient: { _ in server },
                capability: { false }, ownerEndpoint: { nil }, ownerKey: { _ in "" })
        } catch { return nil }
    }
    private static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HouseholdFailure.invalid }; return value
    }
    private static func fixture(_ file: String, key: String) throws -> Data {
        guard let url = Bundle.main.url(forResource: file, withExtension: "json"), let value = try dictionary(Data(contentsOf: url))[key] else { throw HouseholdFailure.invalid }
        return try JSONSerialization.data(withJSONObject: value)
    }
}

@MainActor private final class PersonalRoutinePreviewVault: HouseholdVault {
    var state: HouseholdVaultState
    init(state: HouseholdVaultState) { self.state = state }
    func load() throws -> HouseholdVaultState { state }
    func save(_ state: HouseholdVaultState) throws { self.state = state }
}

private actor PersonalRoutinePreviewServer: HouseholdTransport, PersonalRoutineTransport {
    let account: HouseholdSession
    let original: PersonalRoutineReview
    let mode: String
    var liveWeek: [BedtimeRoutineSnapshot]
    var draftWeek: [HouseholdRoutine]
    var revision: Int
    var receipts: [UUID: PersonalRoutineReceipt] = [:]
    init(account: HouseholdSession, review: PersonalRoutineReview, mode: String) {
        self.account = account; original = review; self.mode = mode
        liveWeek = review.liveWeek; draftWeek = review.draftWeek; revision = review.draftRevision
    }
    func session() async throws -> HouseholdSession { account }
    func review() async throws -> PersonalRoutineReview {
        let changes = PersonalRoutineChange.between(PersonalRoutineWeek.drafts(liveWeek), draftWeek)
        let reason = mode == "disabled" ? "publication_disabled" : revision == 1 ? "draft_not_prepared" : changes.isEmpty ? "unchanged" : "ready"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(draftWeek) + encoder.encode(liveWeek) + Data(String(revision).utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return .init(version: 1, scope: original.scope, sourceSide: original.sourceSide, temperatureZones: original.temperatureZones,
            timeZone: original.timeZone, draftRevision: revision, liveRevision: original.liveRevision, reviewRevision: digest,
            liveWeek: liveWeek, draftWeek: draftWeek, changes: changes, canPublish: reason == "ready", reason: reason, effect: original.effect)
    }
    func publish(_ body: Data) async throws -> PersonalRoutineReceipt {
        let request = try PersonalRoutineRequest.decodeExact(body), reviewed = try await review()
        guard request.reviewRevision == reviewed.reviewRevision, reviewed.canPublish else { throw HouseholdFailure.conflict }
        liveWeek = draftWeek.map { .init(dayOfWeek: $0.dayOfWeek, revision: String(repeating: "f", count: 64), draft: $0.draft) }
        let receipt = PersonalRoutineReceipt(version: 1, requestId: request.requestId, scope: request.scope, sourceSide: reviewed.sourceSide,
            publishedAt: request.issuedAt + 100, draftRevision: revision, reviewRevision: reviewed.reviewRevision,
            state: "saved", scheduler: mode == "pending" ? "pending" : mode == "unconfirmed" ? "unconfirmed" : "refreshed",
            publishedWeek: liveWeek, changes: reviewed.changes, physicalVerification: "unverified", replayAllowed: false)
        receipts[request.requestId] = receipt
        if mode == "unknown" { throw PersonalRoutineFailure.uncertain }
        return receipt
    }
    func publication(_ requestId: UUID) async throws -> PersonalRoutineReceipt {
        guard let receipt = receipts[requestId] else { throw PersonalRoutineFailure.missingReceipt }; return receipt
    }
    func send(path: String, method: String, token: String?, body: Data?) async throws -> Data {
        switch path {
        case "household/session": return try JSONEncoder().encode(account)
        case "me/preferences": return try JSONEncoder().encode(HouseholdPreferencesResponse(sleeperId: account.selfSleeperId, revision: 1, preferences: .blank))
        case "me/routines":
            if method == "PUT", let body,
               let object = try JSONSerialization.jsonObject(with: body) as? [String: Any], let week = object["routines"] {
                draftWeek = try JSONDecoder().decode([HouseholdRoutine].self, from: JSONSerialization.data(withJSONObject: week)); revision += 1
            }
            return try JSONEncoder().encode(HouseholdRoutinesResponse(sleeperId: account.selfSleeperId, revision: revision, status: "draft_only", routines: draftWeek))
        case "household/devices": return Data(#"{"devices":[{"id":"00000000-0000-4000-8000-000000000008","name":"Preview phone","createdAt":"2026-10-29T20:00:00Z","current":true}]}"#.utf8)
        case "household/invitations": return Data(#"{"invitations":[]}"#.utf8)
        default: throw HouseholdFailure.unavailable
        }
    }
}
#endif
