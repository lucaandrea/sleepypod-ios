import XCTest
@testable import Sleepypod

enum PersonalRoutineFixtures {
    static func decode<Value: Decodable>(_ key: String, as type: Value.Type = Value.self) throws -> Value {
        try JSONDecoder().decode(type, from: PersonalControlFixtures.data(key, file: "personal-routines-v1"))
    }
    static func review() throws -> PersonalRoutineReview { try decode("readyReview") }
    static func changed<Value: Codable>(_ value: Value, _ edit: (inout [String: Any]) -> Void) throws -> Value {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        edit(&object)
        return try JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: object))
    }
    static func session(enabled: Bool = true) throws -> HouseholdSession {
        try changed(PersonalControlFixtures.session(for: PersonalControlFixtures.bed())) {
            var capabilities = $0["capabilities"] as? [String: Any] ?? [:]
            capabilities["personalRoutinePublication"] = enabled; $0["capabilities"] = capabilities
        }
    }
    static func attempt(review: PersonalRoutineReview? = nil) throws -> PersonalRoutineAttempt {
        let review = try review ?? Self.review()
        let request = try PersonalRoutineRequest(review: review, now: PersonalControlFixtures.instant)
        return .init(request: request, body: try JSONEncoder().encode(request), review: review)
    }
    static func receipt(_ request: PersonalRoutineRequest, review: PersonalRoutineReview, scheduler: String = "refreshed") -> PersonalRoutineReceipt {
        .init(version: 1, requestId: request.requestId, scope: request.scope, sourceSide: review.sourceSide,
              publishedAt: request.issuedAt + 100, draftRevision: review.draftRevision, reviewRevision: review.reviewRevision,
              state: "saved", scheduler: scheduler, publishedWeek: review.draftWeek.map {
                  .init(dayOfWeek: $0.dayOfWeek, revision: String(repeating: "f", count: 64), draft: $0.draft)
              }, changes: review.changes, physicalVerification: "unverified", replayAllowed: false)
    }
}

@MainActor final class PersonalRoutineLedger {
    var attempts: [PersonalRoutineAttempt] = []
    var active = true
    var ready = true
    var reject = false
    var recoveries = false
    var draft: HouseholdRoutinesResponse
    init(review: PersonalRoutineReview) { draft = .init(sleeperId: review.scope.sleeperId, revision: review.draftRevision, status: "draft_only", routines: review.draftWeek) }
    func save(_ attempt: PersonalRoutineAttempt) throws {
        if reject { throw HouseholdFailure.storage }
        if let index = attempts.firstIndex(where: { $0.id == attempt.id }) { attempts[index] = attempt }
        else { attempts.append(attempt) }
    }
    func workspace(_ server: PersonalRoutineTestServer, session: HouseholdSession) -> PersonalRoutineWorkspace {
        .init(connection: .init(id: UUID(), endpoint: URL(string: "https://routine-fixture.invalid")!, token: String(repeating: "A", count: 43), session: session),
              client: server, permitted: { self.active }, ready: { self.ready }, savedDraft: { self.draft },
              load: { self.attempts }, save: { try self.save($0) }, recoveryPending: { self.recoveries }, now: { PersonalControlFixtures.instant })
    }
}

actor PersonalRoutineTestServer: PersonalRoutineTransport, HouseholdTransport {
    var account: HouseholdSession
    var snapshot: PersonalRoutineReview
    var posts: [Data] = []
    var lookups: [UUID] = []
    var receipts: [UUID: PersonalRoutineReceipt] = [:]
    var postFailure: HouseholdFailure?
    var sessionFailure: HouseholdFailure?
    var missing = false
    var scheduler = "refreshed"
    private var heldRoute: String?
    private var continuation: CheckedContinuation<Void, Never>?
    var onPost: (@Sendable (Data) async -> Void)?
    init(review: PersonalRoutineReview, session: HouseholdSession) { snapshot = review; account = session }
    func configure(postFailure: HouseholdFailure? = nil, sessionFailure: HouseholdFailure? = nil, scheduler: String = "refreshed", missing: Bool = false) {
        self.postFailure = postFailure; self.sessionFailure = sessionFailure; self.scheduler = scheduler; self.missing = missing
    }
    func setReview(_ value: PersonalRoutineReview) { snapshot = value }
    func setSession(_ value: HouseholdSession) { account = value }
    func setReceipt(_ value: PersonalRoutineReceipt) { receipts[value.requestId] = value }
    func setOnPost(_ action: @escaping @Sendable (Data) async -> Void) { onPost = action }
    func hold(_ route: String) { heldRoute = route }
    func waitHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    private func pause(_ route: String) async { if heldRoute == route { heldRoute = nil; await withCheckedContinuation { continuation = $0 } } }
    func session() async throws -> HouseholdSession {
        let value = account; await pause("session")
        if let sessionFailure { throw sessionFailure }; return value
    }
    func review() async throws -> PersonalRoutineReview { let value = snapshot; await pause("review"); return value }
    func publish(_ body: Data) async throws -> PersonalRoutineReceipt {
        posts.append(body); await onPost?(body)
        let request = try PersonalRoutineRequest.decodeExact(body)
        let result = PersonalRoutineFixtures.receipt(request, review: snapshot, scheduler: scheduler)
        receipts[request.requestId] = result; await pause("post")
        if let postFailure { throw postFailure }; return result
    }
    func publication(_ requestId: UUID) async throws -> PersonalRoutineReceipt {
        lookups.append(requestId); let value = receipts[requestId]; await pause("receipt")
        if missing { throw PersonalRoutineFailure.missingReceipt }; return try XCTUnwrap(value)
    }
    func send(path: String, method: String, token: String?, body: Data?) async throws -> Data {
        if path == "household/join" { return try JSONEncoder().encode(account) }
        if path == "household/session" { return try JSONEncoder().encode(try await session()) }
        if path == "me/routines" {
            if method == "PUT", let body {
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let week = try JSONDecoder().decode([HouseholdRoutine].self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(object["routines"])))
                snapshot = try PersonalRoutineFixtures.changed(snapshot) {
                    $0["draftWeek"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(week))
                    $0["draftRevision"] = snapshot.draftRevision + 1
                }
            }
            return try JSONEncoder().encode(HouseholdRoutinesResponse(sleeperId: account.selfSleeperId, revision: snapshot.draftRevision, status: "draft_only", routines: snapshot.draftWeek))
        }
        if path == "me/preferences" { return try JSONEncoder().encode(HouseholdPreferencesResponse(sleeperId: account.selfSleeperId, revision: 1, preferences: .blank)) }
        if path == "household/devices" { return Data(#"{"devices":[{"id":"00000000-0000-4000-8000-000000000008","name":"Fixture phone","createdAt":"2026-10-29T20:00:00Z","current":true}]}"#.utf8) }
        if path == "household/invitations" { return Data(#"{"invitations":[]}"#.utf8) }
        throw HouseholdFailure.unavailable
    }
}
