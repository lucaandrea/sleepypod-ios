#if DEBUG
import Foundation
import FreeSleepKit

/// UI verification uses synthetic people and an in-memory server, with no hardware transport.
@MainActor enum ArrangementReviewPreview {
    static func make() -> HouseholdWorkspace? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--arrangement-fixture"), arguments.indices.contains(index + 1) else { return nil }
        do {
            let mode = arguments[index + 1], member = mode == "member"
            var projection = try fixture("arrangement-review-v1", key: member ? "memberReview" : "ownerReview")
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            projection["createdAt"] = now - 5_000; projection["expiresAt"] = mode == "expired" ? now - 1_000 : now + 3_600_000
            if mode == "expired" || mode == "stale" { projection["state"] = mode; projection["canApprove"] = false }
            let review = try ArrangementReview.decodeExact(JSONSerialization.data(withJSONObject: projection))
            var account = try fixture("household-preparation-v1", key: member ? "memberSession" : "ownerSession")
            account["podId"] = review.podId; account["householdId"] = review.householdId; account["selfSleeperId"] = review.sleeperId
            account["assignmentRevision"] = review.assignmentRevision
            account["arrangement"] = ["mode": "solo-anywhere", "effectiveAt": "2026-10-29T20:00:00Z"]
            account["self"] = ["displayName": review.person.displayName, "zones": member ? [] : ["left", "right"], "assignment": review.person.assignmentAtReview]
            var capabilities = account["capabilities"] as? [String: Any] ?? [:]
            capabilities["arrangementReview"] = mode != "disabled"; capabilities["personalControls"] = false
            capabilities["personalRoutinePublication"] = false; account["capabilities"] = capabilities
            let session = try JSONDecoder().decode(HouseholdSession.self, from: JSONSerialization.data(withJSONObject: account))
            let record = HouseholdConnectionRecord(id: UUID(), endpoint: URL(string: "https://arrangement-preview.invalid")!, deviceSecret: String(repeating: "A", count: 43), identity: session)
            let vault = ArrangementPreviewVault(state: .init(connections: [record], selected: record.id))
            let defaults = UserDefaults(suiteName: "arrangement-review-preview")!
            defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
            let server = ArrangementPreviewServer(account: session, review: review, mode: mode)
            return HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in server }, arrangementClient: { _ in server }, capability: { false }, ownerEndpoint: { nil }, ownerKey: { _ in "" })
        } catch { return nil }
    }
    private static func fixture(_ file: String, key: String) throws -> [String: Any] {
        guard let url = Bundle.main.url(forResource: file, withExtension: "json"),
              let value = try ArrangementJSON.object(Data(contentsOf: url))[key] as? [String: Any] else { throw HouseholdFailure.invalid }
        return value
    }
}

@MainActor private final class ArrangementPreviewVault: HouseholdVault {
    var state: HouseholdVaultState
    init(state: HouseholdVaultState) { self.state = state }
    func load() throws -> HouseholdVaultState { state }
    func save(_ state: HouseholdVaultState) throws { self.state = state }
}

private actor ArrangementPreviewServer: ArrangementReviewTransport, HouseholdTransport {
    let account: HouseholdSession
    let original: ArrangementReview
    let mode: String
    var current: ArrangementReview?
    init(account: HouseholdSession, review: ArrangementReview, mode: String) {
        self.account = account; original = review; self.mode = mode; current = mode == "propose" ? nil : review
    }
    func session() async throws -> HouseholdSession { account }
    func latest() async throws -> ArrangementIndex { .init(version: 1, review: current) }
    func review(_ id: UUID) async throws -> ArrangementReview {
        guard let current, UUID(uuidString: current.reviewId) == id else { throw HouseholdFailure.unavailable }; return current
    }
    func send(_ action: ArrangementRequest.Action, body: Data) async throws -> ArrangementReview {
        let request = try ArrangementRequest.decodeExact(body, action: action, session: account)
        var result = current ?? original
        switch action {
        case .propose:
            var object = try ArrangementJSON.object(JSONEncoder().encode(original)); object["reviewId"] = request.requestId
            var person = object["self"] as? [String: Any] ?? [:]; person["proposedSide"] = request.ownerSide?.rawValue; object["self"] = person
            var partner = object["partner"] as? [String: Any] ?? [:]; partner["proposedSide"] = request.ownerSide == .left ? "right" : "left"; object["partner"] = partner
            result = try ArrangementReview.decodeExact(JSONSerialization.data(withJSONObject: object))
        case .approve: result.person.approved = true; result.canApprove = false
        case .cancel: result.state = .cancelled; result.canApprove = false
        }
        current = result
        if mode == "unknown" { throw HouseholdFailure.uncertain }
        return result
    }
    func send(path: String, method: String, token: String?, body: Data?) async throws -> Data {
        guard method == "GET" else { throw HouseholdFailure.forbidden }
        switch path {
        case "household/session": return try JSONEncoder().encode(account)
        case "me/preferences": return try JSONEncoder().encode(HouseholdPreferencesResponse(sleeperId: account.selfSleeperId, revision: 2, preferences: original.person.preferences))
        case "me/routines": return try JSONEncoder().encode(HouseholdRoutinesResponse(sleeperId: account.selfSleeperId, revision: 2, status: "draft_only", routines: original.person.week))
        case "household/devices": return Data(#"{"devices":[{"id":"00000000-0000-4000-8000-000000000008","name":"Preview phone","createdAt":"2026-10-29T20:00:00Z","current":true}]}"#.utf8)
        case "household/invitations": return Data(#"{"invitations":[]}"#.utf8)
        default: throw HouseholdFailure.unavailable
        }
    }
}
#endif
