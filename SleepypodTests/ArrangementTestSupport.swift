import XCTest
@testable import Sleepypod

enum ArrangementFixtures {
    static func data(_ key: String) throws -> Data { try PersonalControlFixtures.data(key, file: "arrangement-review-v1") }
    static func review(member: Bool = false) throws -> ArrangementReview { try ArrangementReview.decodeExact(data(member ? "memberReview" : "ownerReview")) }
    static func session(member: Bool = false, enabled: Bool = true) throws -> HouseholdSession {
        let projection = try review(member: member)
        let value = try JSONDecoder().decode(HouseholdSession.self, from: PersonalControlFixtures.data(member ? "memberSession" : "ownerSession", file: "household-preparation-v1"))
        return try PersonalRoutineFixtures.changed(value) {
            $0["podId"] = projection.podId; $0["householdId"] = projection.householdId; $0["selfSleeperId"] = projection.sleeperId
            $0["assignmentRevision"] = projection.assignmentRevision; $0["sessionRevision"] = 1
            $0["arrangement"] = ["mode": "solo-anywhere", "effectiveAt": "2026-10-29T20:00:00Z"]
            $0["self"] = ["displayName": projection.person.displayName, "zones": member ? [] : ["left", "right"], "assignment": projection.person.assignmentAtReview]
            var capabilities = $0["capabilities"] as? [String: Any] ?? [:]
            capabilities["arrangementReview"] = enabled; capabilities["personalControls"] = false
            capabilities["personalRoutinePublication"] = false; $0["capabilities"] = capabilities
        }
    }
    static func connection(_ session: HouseholdSession) -> PersonalBedConnection {
        .init(id: UUID(), endpoint: URL(string: "https://arrangement-fixture.invalid")!, token: String(repeating: "A", count: 43), session: session)
    }
}

@MainActor final class ArrangementTestContext {
    var now: Int64 = 1_793_311_201_000
    var permitted = true
    var ready = true
    var revocations = 0
    func workspace(_ server: ArrangementTestServer, session: HouseholdSession) -> ArrangementReviewWorkspace {
        .init(connection: ArrangementFixtures.connection(session), client: server,
              permitted: { self.permitted }, ready: { self.ready }, revoked: { self.revocations += 1 }, now: { self.now })
    }
    func confirm(_ model: ArrangementReviewWorkspace) {
        model.confirmMySide = true; model.confirmMyRoutine = true; model.acknowledgeSeparateActivation = true
    }
}

actor ArrangementTestServer: ArrangementReviewTransport, HouseholdTransport {
    var account: HouseholdSession
    var projection: ArrangementReview?
    let original: ArrangementReview
    var posts: [(ArrangementRequest.Action, Data)] = []
    var reads: [String] = []
    var postFailure: HouseholdFailure?
    var sessionFailure: HouseholdFailure?
    private var held: String?
    private var continuation: CheckedContinuation<Void, Never>?
    init(member: Bool = false, empty: Bool = false, enabled: Bool = true) throws {
        account = try ArrangementFixtures.session(member: member, enabled: enabled)
        original = try ArrangementFixtures.review(member: member); projection = empty ? nil : original
    }
    func setReview(_ value: ArrangementReview?) { projection = value }
    func setSession(_ value: HouseholdSession) { account = value }
    func configure(postFailure: HouseholdFailure? = nil, sessionFailure: HouseholdFailure? = nil) {
        self.postFailure = postFailure; self.sessionFailure = sessionFailure
    }
    func hold(_ route: String) { held = route }
    func waitHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    private func pause(_ route: String) async { if held == route { held = nil; await withCheckedContinuation { continuation = $0 } } }
    func session() async throws -> HouseholdSession {
        let value = account; await pause("session")
        if let sessionFailure { throw sessionFailure }; return value
    }
    func latest() async throws -> ArrangementIndex {
        reads.append("latest"); let value = projection; await pause("latest"); return .init(version: 1, review: value)
    }
    func review(_ id: UUID) async throws -> ArrangementReview {
        reads.append(id.uuidString.lowercased()); await pause("review")
        guard let projection, UUID(uuidString: projection.reviewId) == id else { throw HouseholdFailure.unavailable }
        return projection
    }
    func send(_ action: ArrangementRequest.Action, body: Data) async throws -> ArrangementReview {
        let request = try ArrangementRequest.decodeExact(body, action: action, session: account)
        posts.append((action, body))
        var result = projection ?? original
        if action == .propose {
            result = try PersonalRoutineFixtures.changed(original) {
                $0["reviewId"] = request.requestId
                var person = $0["self"] as? [String: Any] ?? [:]; person["proposedSide"] = request.ownerSide?.rawValue; $0["self"] = person
                var partner = $0["partner"] as? [String: Any] ?? [:]; partner["proposedSide"] = request.ownerSide == .left ? "right" : "left"; $0["partner"] = partner
            }
        } else if action == .approve {
            result.person.approved = true; result.canApprove = false
            if result.partner.approved { result.state = .approved }
        } else { result.state = .cancelled; result.canApprove = false }
        projection = result; await pause("post")
        if let postFailure { throw postFailure }; return result
    }
    func send(path: String, method: String, token: String?, body: Data?) async throws -> Data {
        guard method == "GET" else { throw HouseholdFailure.forbidden }
        switch path {
        case "household/session": return try JSONEncoder().encode(try await session())
        case "me/preferences": return try JSONEncoder().encode(HouseholdPreferencesResponse(sleeperId: account.selfSleeperId, revision: 2, preferences: original.person.preferences))
        case "me/routines": return try JSONEncoder().encode(HouseholdRoutinesResponse(sleeperId: account.selfSleeperId, revision: 2, status: "draft_only", routines: original.person.week))
        case "household/devices": return Data(#"{"devices":[{"id":"00000000-0000-4000-8000-000000000008","name":"Fixture phone","createdAt":"2026-10-29T20:00:00Z","current":true}]}"#.utf8)
        case "household/invitations": return Data(#"{"invitations":[]}"#.utf8)
        default: throw HouseholdFailure.unavailable
        }
    }
}

@MainActor final class ArrangementTestVault: HouseholdVault {
    var state: HouseholdVaultState
    init(_ session: HouseholdSession) {
        let connection = ArrangementFixtures.connection(session)
        let record = HouseholdConnectionRecord(id: connection.id, endpoint: connection.endpoint, deviceSecret: connection.token, identity: session)
        state = .init(connections: [record], selected: record.id)
    }
    func load() throws -> HouseholdVaultState { state }
    func save(_ state: HouseholdVaultState) throws { self.state = state }
}
