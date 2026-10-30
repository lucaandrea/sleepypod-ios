import XCTest
@testable import Sleepypod

enum PersonalHistoryFixtures {
    static func changed<Value: Codable>(_ value: Value, _ mutation: (inout [String: Any]) throws -> Void) throws -> Value {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        try mutation(&object)
        return try JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: object))
    }
    static func data(_ key: String) throws -> Data { try PersonalControlFixtures.data(key, file: "personal-history-v1") }
    static func page(_ key: String = "page") throws -> PersonalHistoryPage { try .decodeExact(data(key)) }
    static func detail() throws -> PersonalHistoryDetail { try .decodeExact(data("detail")) }
    static func session(enabled: Bool = true) throws -> HouseholdSession {
        let original = try JSONDecoder().decode(HouseholdSession.self, from: PersonalControlFixtures.data("ownerSession", file: "household-preparation-v1"))
        let scope = try page().scope
        return try PersonalHistoryFixtures.changed(original) {
            $0["podId"] = scope.podId; $0["householdId"] = scope.householdId; $0["accountId"] = scope.accountId
            $0["selfSleeperId"] = scope.sleeperId; $0["sessionRevision"] = scope.sessionRevision
            $0["householdRevision"] = scope.householdRevision; $0["assignmentRevision"] = scope.assignmentRevision
            var capabilities = $0["capabilities"] as? [String: Any] ?? [:]
            capabilities["personalHistory"] = enabled; $0["capabilities"] = capabilities
        }
    }
    static func connection(_ session: HouseholdSession) -> PersonalBedConnection {
        .init(id: UUID(), endpoint: URL(string: "https://history-fixture.invalid")!, token: String(repeating: "A", count: 43), session: session)
    }
    static func object(_ key: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data(key)) as? [String: Any]) }
}

actor PersonalHistoryTestServer: PersonalHistoryTransport {
    var account: HouseholdSession
    var pages: [PersonalHistoryPage]
    var recorded: PersonalHistoryDetail
    var failure: HouseholdFailure?
    var sessionFailure: HouseholdFailure?
    var requests: [String] = []
    var queries: [PersonalHistoryQuery] = []
    private var held: String?
    private var continuation: CheckedContinuation<Void, Never>?
    init(enabled: Bool = true) throws {
        account = try PersonalHistoryFixtures.session(enabled: enabled)
        pages = [try PersonalHistoryFixtures.page()]; recorded = try PersonalHistoryFixtures.detail()
    }
    func setSession(_ value: HouseholdSession) { account = value }
    func configure(pages: [PersonalHistoryPage]? = nil, detail: PersonalHistoryDetail? = nil, failure: HouseholdFailure? = nil, sessionFailure: HouseholdFailure? = nil) {
        if let pages { self.pages = pages }; if let detail { recorded = detail }
        self.failure = failure; self.sessionFailure = sessionFailure
    }
    func hold(_ route: String) { held = route }
    func waitHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    private func pause(_ route: String) async { if held == route { held = nil; await withCheckedContinuation { continuation = $0 } } }
    func session() async throws -> HouseholdSession {
        requests.append("session"); let result = account; await pause("session")
        if let sessionFailure { throw sessionFailure }; return result
    }
    func page(_ query: PersonalHistoryQuery, cursor: String?) async throws -> PersonalHistoryPage {
        queries.append(query); requests.append(cursor ?? "first"); let result = pages.count > 1 ? pages.removeFirst() : pages[0]
        await pause("page"); if let failure { throw failure }
        return try PersonalHistoryFixtures.changed(result) { $0["query"] = try HouseholdRequestBody.object(query) }
    }
    func detail(_ id: UUID) async throws -> PersonalHistoryDetail {
        requests.append(id.uuidString.lowercased()); let result = recorded
        await pause("detail"); if let failure { throw failure }; return result
    }
}

@MainActor final class PersonalHistoryTestContext {
    var permitted = true
    var revocations = 0
    var now: Int64 = 1_793_397_600_000
    func workspace(_ server: PersonalHistoryTestServer, session: HouseholdSession? = nil) throws -> PersonalHistoryWorkspace {
        .init(connection: PersonalHistoryFixtures.connection(try session ?? PersonalHistoryFixtures.session()), client: server, pageSize: 1,
              permitted: { self.permitted }, revoked: { self.revocations += 1 }, now: { self.now })
    }
}
