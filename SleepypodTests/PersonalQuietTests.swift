import XCTest
@testable import Sleepypod

enum PersonalQuietFixtures {
    static func data(_ key: String) throws -> Data { try PersonalControlFixtures.data(key, file: "personal-quiet-v1") }
    static func session(_ key: String = "session") throws -> HouseholdSession { try JSONDecoder().decode(HouseholdSession.self, from: data(key)) }
    static func page(_ key: String = "idle") throws -> PersonalQuietPage { try .decodeExact(data(key)) }
    static func connection() throws -> PersonalBedConnection { PersonalHistoryFixtures.connection(try session()) }
}

final class PersonalQuietContractTests: XCTestCase {
    func testRealCoreAPIProjectionsPreserveIndependentRequests() throws {
        let session = try PersonalQuietFixtures.session()
        try session.validate()
        for key in ["idle", "shared", "partner"] { try PersonalQuietFixtures.page(key).validate(for: session) }
        for key in ["saved", "cleared", "missing"] {
            try PersonalQuietResult.decodeExact(PersonalQuietFixtures.data(key)).validate(for: session)
        }
        let shared = try PersonalQuietFixtures.page("shared"), partner = try PersonalQuietFixtures.page("partner")
        XCTAssertGreaterThan(try XCTUnwrap(shared.shared.until), try XCTUnwrap(shared.mine.until))
        XCTAssertNil(partner.mine.until); XCTAssertTrue(partner.shared.paused)
        XCTAssertEqual(partner.shared.until, shared.shared.until)
        XCTAssertEqual(try PersonalQuietFixtures.session("memberSession").person.assignment, "unassigned")
    }
    func testClearEncodesExplicitNullsWithoutChoosingAnotherSleeper() throws {
        let request = PersonalQuietWrite(requestId: UUID().uuidString, expectedSessionRevision: 1, expectedAssignmentRevision: 1,
            expectedRevision: nil, issuedAt: 1000, expiresAt: 31_000, until: nil)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertTrue(object["expectedRevision"] is NSNull); XCTAssertTrue(object["until"] is NSNull)
        XCTAssertEqual(Set(object.keys), ["requestId", "expectedSessionRevision", "expectedAssignmentRevision", "expectedRevision", "issuedAt", "expiresAt", "until"])
    }
    func testRejectsBroaderPrivateDataAndWrongScope() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: PersonalQuietFixtures.data("idle")) as? [String: Any])
        object["otherPerson"] = "private"
        XCTAssertThrowsError(try PersonalQuietPage.decodeExact(JSONSerialization.data(withJSONObject: object)))
        let changed = try PersonalHistoryFixtures.changed(PersonalQuietFixtures.session()) { $0["householdRevision"] = ($0["householdRevision"] as! Int) + 1 }
        XCTAssertThrowsError(try PersonalQuietFixtures.page().validate(for: changed))
    }
    func testRejectsExpiredOrContradictorySharedState() throws {
        let source = try PersonalQuietFixtures.page("shared"), session = try PersonalQuietFixtures.session()
        for shared in [PersonalQuietPage.Shared(paused: false, until: source.shared.until), .init(paused: true, until: nil),
                       .init(paused: true, until: source.generatedAt), .init(paused: true, until: source.generatedAt + 1)] {
            let page = PersonalQuietPage(version: 1, generatedAt: source.generatedAt, scope: source.scope, mine: source.mine, shared: shared)
            XCTAssertThrowsError(try page.validate(for: session))
        }
    }
    func testRejectsLongLivedWritesAndUnboundedQuiet() {
        for (expiry, until) in [(61_001, 30_000), (1000, 30_000), (31_000, 1000), (31_000, 86_401_001)] {
            let request = PersonalQuietWrite(requestId: UUID().uuidString, expectedSessionRevision: 1, expectedAssignmentRevision: 1,
                expectedRevision: nil, issuedAt: 1000, expiresAt: Int64(expiry), until: Int64(until))
            XCTAssertThrowsError(try request.validate())
        }
    }
}

actor PersonalQuietTestServer: PersonalQuietTransport {
    var account: HouseholdSession
    let scope: PersonalHistoryScope
    var clock: Int64
    var revision: String?
    var ownerEnd: Int64?
    var partnerEnd: Int64?
    var lastReceipt: PersonalQuietReceipt?
    private(set) var writes: [PersonalQuietWrite] = []
    private(set) var sessionReads = 0
    var lostReply = false
    var skipCommit = false
    var missingReceipt = false
    var badReceipt = false
    var failure: HouseholdFailure?
    var holdReading = false
    var continuation: CheckedContinuation<Void, Never>?
    init() throws {
        account = try PersonalQuietFixtures.session()
        let initial = try PersonalQuietFixtures.page(); scope = initial.scope; clock = initial.generatedAt
        partnerEnd = clock + 7_200_000
    }
    func configure(lostReply: Bool = false, skipCommit: Bool = false, missingReceipt: Bool = false, badReceipt: Bool = false,
                   failure: HouseholdFailure? = nil, account: HouseholdSession? = nil) {
        self.lostReply = lostReply; self.skipCommit = skipCommit; self.missingReceipt = missingReceipt
        self.badReceipt = badReceipt; self.failure = failure
        if let account { self.account = account }
    }
    func setClock(_ value: Int64) { clock = value }
    func changeFromAnotherDevice() { revision = UUID().uuidString }
    func hold() { holdReading = true }
    func waitHeld() async throws {
        for _ in 0..<200 { if continuation != nil { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw HouseholdFailure.uncertain
    }
    func release() { continuation?.resume(); continuation = nil }
    func session() async throws -> HouseholdSession { sessionReads += 1; if let failure { throw failure }; return account }
    func read() async throws -> PersonalQuietPage {
        let own = ownerEnd.flatMap { $0 > clock ? $0 : nil }
        let shared = [own, partnerEnd].compactMap { $0 }.filter { $0 > clock }.max()
        let result = PersonalQuietPage(version: 1, generatedAt: clock, scope: scope,
            mine: .init(revision: revision, until: own), shared: .init(paused: shared != nil, until: shared))
        if holdReading { holdReading = false; await withCheckedContinuation { continuation = $0 } }
        return result
    }
    func write(_ input: PersonalQuietWrite) async throws -> PersonalQuietResult {
        writes.append(input)
        if !skipCommit {
            revision = UUID().uuidString; ownerEnd = input.until
            lastReceipt = .init(requestId: input.requestId, revision: revision!, savedAt: clock, until: input.until)
        }
        if lostReply { throw HouseholdFailure.uncertain }
        return try await receipt(requestId: input.requestId)
    }
    func receipt(requestId: String) async throws -> PersonalQuietResult {
        var receipt = missingReceipt ? nil : lastReceipt
        if badReceipt, let value = receipt { receipt = .init(requestId: UUID().uuidString, revision: value.revision, savedAt: value.savedAt, until: value.until) }
        return .init(version: 1, generatedAt: clock, scope: scope, receipt: receipt)
    }
}

@MainActor final class PersonalQuietWorkspaceTests: XCTestCase {
    private final class Clock {
        var milliseconds: Int64
        var uptime: TimeInterval = 100
        init() throws { milliseconds = try PersonalQuietFixtures.page().generatedAt }
        var date: Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }
    }
    private func workspace(_ server: PersonalQuietTestServer, clock: Clock) throws -> PersonalQuietWorkspace {
        try .init(connection: PersonalQuietFixtures.connection(), client: server, now: { clock.date }, uptime: { clock.uptime })
    }
    func testStartAndEndPreservePartnerAndNeverResendOnRefresh() async throws {
        let server = try PersonalQuietTestServer(), clock = try Clock(), model = try workspace(server, clock: clock)
        await model.refresh(); XCTAssertTrue(model.editable)
        await model.change(minutes: 60); XCTAssertNotNil(model.currentPage?.mine.until); XCTAssertNil(model.pending)
        await model.change(minutes: nil)
        XCTAssertNil(model.currentPage?.mine.until); XCTAssertTrue(model.currentPage?.shared.paused == true)
        await model.refresh(); await model.refresh(); await model.reconcile()
        let count = await server.writes.count; XCTAssertEqual(count, 2)
    }
    func testLostReplySurvivesBackgroundAndReconcilesWithoutAnotherWrite() async throws {
        let server = try PersonalQuietTestServer(), clock = try Clock(), model = try workspace(server, clock: clock)
        await model.refresh(); await server.configure(lostReply: true); await model.change(minutes: 60)
        XCTAssertNotNil(model.pending); XCTAssertFalse(model.editable); XCTAssertNil(model.currentPage)
        model.suspend(); XCTAssertNotNil(model.pending)
        await model.refresh(); await model.change(minutes: 120); await model.reconcile()
        XCTAssertNil(model.pending); XCTAssertNotNil(model.currentPage?.mine.until)
        let count = await server.writes.count; XCTAssertEqual(count, 1)
    }
    func testAbsentReceiptCannotClearUncertaintyUntilFreshControllerClockPassesExpiry() async throws {
        let server = try PersonalQuietTestServer(), clock = try Clock(), model = try workspace(server, clock: clock)
        await model.refresh(); await server.configure(lostReply: true, skipCommit: true, missingReceipt: true)
        await model.change(minutes: 60); await model.reconcile(); XCTAssertNotNil(model.pending)
        clock.milliseconds += 31_000; clock.uptime += 31
        await server.setClock(clock.milliseconds); await model.reconcile()
        XCTAssertNil(model.pending); XCTAssertTrue(model.editable)
        let count = await server.writes.count; XCTAssertEqual(count, 1)
    }
    func testPollingDoesNotRetryFailedReadsOrUncertainWrites() async throws {
        let server = try PersonalQuietTestServer(), clock = try Clock(), model = try workspace(server, clock: clock)
        await server.configure(failure: .uncertain)
        await model.refresh()
        let failedReads = await server.sessionReads
        await model.poll()
        let afterFailurePoll = await server.sessionReads
        XCTAssertEqual(afterFailurePoll, failedReads)
        await server.configure(lostReply: true)
        await model.refresh(); await model.change(minutes: 60)
        XCTAssertNotNil(model.pending)
        let uncertainReads = await server.sessionReads
        await model.poll()
        let afterUncertainPoll = await server.sessionReads
        XCTAssertEqual(afterUncertainPoll, uncertainReads)
        await model.reconcile()
        XCTAssertNil(model.pending)
        let count = await server.writes.count; XCTAssertEqual(count, 1)
    }
    func testNewRevisionRequiresReviewInsteadOfOverwritingAnotherDevice() async throws {
        let server = try PersonalQuietTestServer(), clock = try Clock(), model = try workspace(server, clock: clock)
        await model.refresh(); await server.changeFromAnotherDevice(); await model.change(minutes: 60)
        XCTAssertNil(model.currentPage); XCTAssertNotNil(model.error)
        let count = await server.writes.count; XCTAssertEqual(count, 0)
    }
    func testFutureStaleAndRolledBackClocksCannotPermitChanges() async throws {
        for offset in [-15_000, 5001] {
            let server = try PersonalQuietTestServer(), clock = try Clock(), model = try workspace(server, clock: clock)
            await server.setClock(clock.milliseconds + Int64(offset)); await model.refresh()
            XCTAssertNil(model.currentPage); XCTAssertFalse(model.editable)
        }
        let server = try PersonalQuietTestServer(), clock = try Clock(), model = try workspace(server, clock: clock)
        await model.refresh(); clock.uptime += 15; model.tick(); XCTAssertFalse(model.fresh)
        await model.refresh(); clock.milliseconds -= 5001; model.tick(); XCTAssertFalse(model.fresh)
    }
    func testExpiredQuietDoesNotAppearLiveBeforeNewReading() async throws {
        let server = try PersonalQuietTestServer(), clock = try Clock(), model = try workspace(server, clock: clock)
        await model.refresh(); await model.change(minutes: 30)
        clock.milliseconds += 1_800_000; clock.uptime += 1800; model.tick()
        XCTAssertNil(model.currentPage); XCTAssertFalse(model.editable)
    }
    func testRevokedAndChangedAccountsWithdrawAllPersonalState() async throws {
        for failure in [HouseholdFailure.authentication, .forbidden, .unavailable] {
            let server = try PersonalQuietTestServer(), clock = try Clock(), model = try workspace(server, clock: clock)
            await model.refresh(); await server.configure(failure: failure); await model.refresh()
            XCTAssertTrue(model.isInvalidated); XCTAssertNil(model.page)
        }
        let server = try PersonalQuietTestServer(), clock = try Clock(), model = try workspace(server, clock: clock)
        await model.refresh()
        let changed = try PersonalHistoryFixtures.changed(PersonalQuietFixtures.session()) { $0["householdRevision"] = ($0["householdRevision"] as! Int) + 1 }
        await server.configure(account: changed); await model.change(minutes: 60)
        XCTAssertTrue(model.isInvalidated)
        let count = await server.writes.count; XCTAssertEqual(count, 0)
    }
    func testLateReadCannotRepopulateBackgroundedScreen() async throws {
        let server = try PersonalQuietTestServer(), clock = try Clock(), model = try workspace(server, clock: clock)
        await server.hold()
        let pending = Task { await model.refresh() }
        try await server.waitHeld(); model.suspend(); await server.release(); await pending.value
        XCTAssertNil(model.page); XCTAssertFalse(model.busy); XCTAssertFalse(model.fresh)
    }
    func testMismatchedReceiptKeepsRequestUncertain() async throws {
        let server = try PersonalQuietTestServer(), clock = try Clock(), model = try workspace(server, clock: clock)
        await model.refresh(); await server.configure(badReceipt: true); await model.change(minutes: 60)
        XCTAssertNotNil(model.pending); XCTAssertNil(model.currentPage)
        let count = await server.writes.count; XCTAssertEqual(count, 1)
    }
}
