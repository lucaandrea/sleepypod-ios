import XCTest
@testable import Sleepypod

enum PersonalPatternsFixtures {
    static let range = PersonalJournalRange(from: "2026-11-01", through: "2026-11-10")
    static func data(_ key: String = "ready") throws -> Data { try PersonalControlFixtures.data(key, file: "personal-journal-patterns-v1") }
    static func session() throws -> HouseholdSession { try JSONDecoder().decode(HouseholdSession.self, from: data("session")) }
    static func response(_ key: String = "ready") throws -> PersonalJournalPatterns { try .decodeExact(data(key)) }
    static func connection() throws -> PersonalBedConnection { PersonalHistoryFixtures.connection(try session()) }
}

final class PersonalJournalPatternsContractTests: XCTestCase {
    func testCoreGeneratedReadyEmptyAndInsufficientResponses() throws {
        for key in ["ready", "empty", "insufficient"] {
            let result = try PersonalPatternsFixtures.response(key)
            try result.validate(for: PersonalPatternsFixtures.session(), range: PersonalPatternsFixtures.range)
        }
        let result = try PersonalPatternsFixtures.response()
        XCTAssertEqual(result.cohorts[0].comparisons[0].withCount, 5)
        XCTAssertEqual(result.cohorts[0].comparisons[0].warmRateDifferencePoints, 100)
        XCTAssertTrue(try PersonalPatternsFixtures.response("insufficient").cohorts[0].comparisons.allSatisfy { $0.warmRateDifferencePoints == nil })
    }
    func testRangesAreInclusiveBoundedAndCalendarValidAcrossDST() throws {
        for range in [PersonalJournalRange(from: "2026-10-01", through: "2026-12-29"), .init(from: "2026-11-01", through: "2026-11-01")] { try range.validate() }
        for range in [PersonalJournalRange(from: "2026-10-01", through: "2026-12-30"), .init(from: "2026-02-30", through: "2026-03-01"),
                      .init(from: "2026-11-02", through: "2026-11-01"), .init(from: "2026-11-01&side=left", through: "2026-11-10")] {
            XCTAssertThrowsError(try range.validate())
        }
    }
    func testRejectsIdentityRangeAndAggregatesThatCouldMisleadTheSleeper() throws {
        let result = try PersonalPatternsFixtures.response(), session = try PersonalPatternsFixtures.session()
        let other: HouseholdSession = try PersonalHistoryFixtures.changed(session) { $0["accountId"] = UUID().uuidString }
        XCTAssertThrowsError(try result.validate(for: other, range: PersonalPatternsFixtures.range))
        XCTAssertThrowsError(try result.validate(for: session, range: .init(from: "2026-11-02", through: "2026-11-10")))
        let changes: [(inout [String: Any]) -> Void] = [
            { $0["withCount"] = 4 }, { $0["withWarmCount"] = 6 }, { $0["warmRateDifferencePoints"] = 7 },
            { $0["excludedCount"] = 1 }, { $0["quantityThreshold"] = 10_001 }, { $0["label"] = String(repeating: "x", count: 121) },
            { $0["id"] = "diagnosis" }
        ]
        for change in changes {
            var object = try JSONSerialization.jsonObject(with: PersonalPatternsFixtures.data()) as! [String: Any]
            var cohorts = object["cohorts"] as! [[String: Any]], comparisons = cohorts[0]["comparisons"] as! [[String: Any]]
            change(&comparisons[0]); cohorts[0]["comparisons"] = comparisons; object["cohorts"] = cohorts
            let altered = try PersonalJournalPatterns.decodeExact(JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try altered.validate(for: session, range: PersonalPatternsFixtures.range))
        }
    }
    func testRejectsBroaderProjectionDuplicateGroupsAndMissingExplicitNulls() throws {
        let raw = try JSONSerialization.jsonObject(with: PersonalPatternsFixtures.data()) as! [String: Any]
        for forbidden in ["side", "origin", "notes", "records"] {
            var object = raw, cohorts = object["cohorts"] as! [[String: Any]]
            cohorts[0][forbidden] = "private"; object["cohorts"] = cohorts
            XCTAssertThrowsError(try PersonalJournalPatterns.decodeExact(JSONSerialization.data(withJSONObject: object)))
        }
        var missing = raw, cohorts = missing["cohorts"] as! [[String: Any]], comparisons = cohorts[0]["comparisons"] as! [[String: Any]]
        comparisons[0].removeValue(forKey: "quantityThreshold"); cohorts[0]["comparisons"] = comparisons; missing["cohorts"] = cohorts
        XCTAssertThrowsError(try PersonalJournalPatterns.decodeExact(JSONSerialization.data(withJSONObject: missing)))
        var duplicate = raw; duplicate["cohorts"] = (raw["cohorts"] as! [[String: Any]]) + (raw["cohorts"] as! [[String: Any]])
        XCTAssertThrowsError(try PersonalJournalPatterns.decodeExact(JSONSerialization.data(withJSONObject: duplicate)).validate(for: PersonalPatternsFixtures.session(), range: PersonalPatternsFixtures.range))
    }
}

actor PersonalPatternsTestServer: PersonalJournalTransport {
    let journal: PersonalJournalTestServer
    var account: HouseholdSession
    private(set) var requests = 0
    var failure: HouseholdFailure?
    var held = false
    var continuation: CheckedContinuation<Void, Never>?
    init() throws { journal = try .init(); account = try PersonalPatternsFixtures.session() }
    func session() async throws -> HouseholdSession { account }
    func read(date: String) async throws -> PersonalJournalPage { try await journal.read(date: date) }
    func write(_ input: PersonalJournalWrite) async throws -> PersonalJournalResult { try await journal.write(input) }
    func receipt(requestId: String) async throws -> PersonalJournalResult { try await journal.receipt(requestId: requestId) }
    func configure(failure: HouseholdFailure? = nil, held: Bool = false, account: HouseholdSession? = nil) {
        self.failure = failure; self.held = held; if let account { self.account = account }
    }
    func waitHeld() async throws {
        for _ in 0..<200 { if continuation != nil { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw HouseholdFailure.uncertain
    }
    func release() { continuation?.resume(); continuation = nil }
    func patterns(range: PersonalJournalRange) async throws -> PersonalJournalPatterns {
        requests += 1
        if held { held = false; await withCheckedContinuation { continuation = $0 } }
        if let failure { throw failure }
        var object = try JSONSerialization.jsonObject(with: PersonalPatternsFixtures.data()) as! [String: Any]
        object["query"] = ["from": range.from, "through": range.through]
        return try .decodeExact(JSONSerialization.data(withJSONObject: object))
    }
}

@MainActor final class PersonalJournalPatternsWorkspaceTests: XCTestCase {
    private func workspace(_ server: PersonalPatternsTestServer) throws -> PersonalJournalWorkspace {
        .init(connection: try PersonalPatternsFixtures.connection(), client: server)
    }
    func testComparisonReadsSavedDataAndPreservesUnsavedDraftWhenReadFails() async throws {
        let server = try PersonalPatternsTestServer(), model = try workspace(server)
        await model.open(date: "2026-11-10")
        var draft = try XCTUnwrap(model.draft); draft.notes = "Private unsaved note"; model.edit(draft)
        await model.comparisons.load(PersonalPatternsFixtures.range)
        XCTAssertNotNil(model.comparisons.result); XCTAssertTrue(model.dirty); XCTAssertEqual(model.draft?.notes, draft.notes)
        await server.configure(failure: .uncertain); await model.comparisons.load(PersonalPatternsFixtures.range)
        XCTAssertNil(model.comparisons.result); XCTAssertNotNil(model.comparisons.error)
        XCTAssertEqual(model.draft?.notes, draft.notes); XCTAssertTrue(model.dirty)
        let writes = await server.journal.writes; XCTAssertTrue(writes.isEmpty)
    }
    func testCloseAndChangingDateDiscardPendingComparisonReplies() async throws {
        let server = try PersonalPatternsTestServer(), model = try workspace(server)
        await model.open(date: "2026-11-10"); await server.configure(held: true)
        let request = Task { await model.comparisons.load(PersonalPatternsFixtures.range) }
        try await server.waitHeld(); model.suspend(); await server.release(); await request.value
        XCTAssertNil(model.page); XCTAssertNil(model.comparisons.result); XCTAssertFalse(model.comparisons.busy)
        await model.open(date: "2026-11-10"); await model.comparisons.load(PersonalPatternsFixtures.range)
        XCTAssertNotNil(model.comparisons.result)
        await model.open(date: "2026-11-09"); XCTAssertNil(model.comparisons.result)
    }
    func testSavingOrClearingAQueryWithdrawsEarlierFindings() async throws {
        let server = try PersonalPatternsTestServer(), model = try workspace(server)
        await model.open(date: "2026-11-10"); await model.comparisons.load(PersonalPatternsFixtures.range)
        model.comparisons.clear(); XCTAssertNil(model.comparisons.result)
        await model.comparisons.load(PersonalPatternsFixtures.range)
        var draft = try XCTUnwrap(model.draft); draft.notes = "Saved replacement"; model.edit(draft)
        await model.save(); XCTAssertNil(model.comparisons.result); XCTAssertFalse(model.dirty)
    }
    func testAccountChangeAfterReadWithdrawsJournalAndComparison() async throws {
        let server = try PersonalPatternsTestServer(), model = try workspace(server)
        await model.open(date: "2026-11-10"); await server.configure(held: true)
        let request = Task { await model.comparisons.load(PersonalPatternsFixtures.range) }
        try await server.waitHeld()
        let changed: HouseholdSession = try PersonalHistoryFixtures.changed(PersonalPatternsFixtures.session()) { $0["sessionRevision"] = 2 }
        await server.configure(account: changed); await server.release(); await request.value
        XCTAssertTrue(model.isInvalidated); XCTAssertNil(model.page); XCTAssertNil(model.draft); XCTAssertNil(model.comparisons.result)
    }
    func testRevocationDuringComparisonInvalidatesTheWholeAccountView() async throws {
        let server = try PersonalPatternsTestServer()
        var revoked = false
        let model = PersonalJournalWorkspace(connection: try PersonalPatternsFixtures.connection(), client: server, revoked: { revoked = true })
        await model.open(date: "2026-11-10"); await server.configure(failure: .authentication)
        await model.comparisons.load(PersonalPatternsFixtures.range)
        XCTAssertTrue(revoked); XCTAssertTrue(model.isInvalidated); XCTAssertNil(model.draft)
    }
    func testInvalidRangeAndUnavailableCapabilityNeverRequestComparisons() async throws {
        let server = try PersonalPatternsTestServer(), model = try workspace(server)
        await model.open(date: "2026-11-10")
        await model.comparisons.load(.init(from: "2026-01-01", through: "2026-11-10"))
        XCTAssertNotNil(model.comparisons.error)
        let disabled = PersonalJournalWorkspace(connection: try PersonalJournalFixtures.connection(), client: server)
        XCTAssertFalse(disabled.comparisons.available)
        await disabled.comparisons.load(PersonalPatternsFixtures.range)
        let requests = await server.requests; XCTAssertEqual(requests, 0)
    }
}
