import XCTest
@testable import Sleepypod

enum PersonalJournalFixtures {
    static func data(_ key: String) throws -> Data { try PersonalControlFixtures.data(key, file: "personal-journal-v1") }
    static func session() throws -> HouseholdSession { try JSONDecoder().decode(HouseholdSession.self, from: data("session")) }
    static func page() throws -> PersonalJournalPage { try .decodeExact(data("page")) }
    static func connection() throws -> PersonalBedConnection { PersonalHistoryFixtures.connection(try session()) }
}

final class PersonalJournalContractTests: XCTestCase {
    func testFrozenCorePageReceiptAndDeletionEncodeExplicitNulls() throws {
        let session = try PersonalJournalFixtures.session(), page = try PersonalJournalFixtures.page()
        try session.validate(); try page.validate(for: session, date: "2026-11-10")
        let result = try PersonalJournalResult.decodeExact(PersonalJournalFixtures.data("receipt"))
        try result.validate(for: session)
        let write = PersonalJournalWrite(requestId: UUID().uuidString, expectedSessionRevision: 1, expectedAssignmentRevision: 1,
            date: "2026-11-10", expectedRevision: nil, expectedTimeZone: "America/Los_Angeles", fields: nil)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(write)) as? [String: Any])
        XCTAssertTrue(object["expectedRevision"] is NSNull); XCTAssertTrue(object["fields"] is NSNull)
        XCTAssertNil(object["side"]); XCTAssertNil(object["accountId"])
    }
    func testRejectsBroaderProjectionWrongDatesAndAccountScope() throws {
        let data = try PersonalJournalFixtures.data("page"), session = try PersonalJournalFixtures.session()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["otherSleeper"] = "private"
        XCTAssertThrowsError(try PersonalJournalPage.decodeExact(JSONSerialization.data(withJSONObject: object)))
        let page = try PersonalJournalFixtures.page()
        XCTAssertThrowsError(try page.validate(for: session, date: "2026-11-09"))
        let changed: HouseholdSession = try PersonalHistoryFixtures.changed(session) { $0["accountId"] = UUID().uuidString }
        XCTAssertThrowsError(try page.validate(for: changed, date: "2026-11-10"))
        let selection = PersonalJournalSelection(date: "2026-02-30", revision: nil, timeZone: nil, record: nil)
        XCTAssertThrowsError(try selection.validate(generatedAt: page.generatedAt))
    }
    func testTombstoneMustKeepRevisionAndTimeZoneTogetherAndRecordsCannotComeFromFuture() throws {
        let page = try PersonalJournalFixtures.page(), entry = try XCTUnwrap(page.entries.first)
        try PersonalJournalSelection(date: entry.date, revision: entry.revision, timeZone: entry.timeZone, record: nil).validate(generatedAt: page.generatedAt)
        XCTAssertThrowsError(try PersonalJournalSelection(date: entry.date, revision: entry.revision, timeZone: nil, record: nil).validate(generatedAt: page.generatedAt))
        XCTAssertThrowsError(try entry.validate(generatedAt: 0))
    }
}

actor PersonalJournalTestServer: PersonalJournalTransport {
    var account: HouseholdSession
    var page: PersonalJournalPage
    var entries: [String: PersonalJournalSelection]
    var receipts: [String: PersonalJournalReceipt] = [:]
    private(set) var writes: [PersonalJournalWrite] = []
    private(set) var reads: [String] = []
    var lostReply = false
    var unknownReceipt = false
    var readError = false
    var held = false
    var continuation: CheckedContinuation<Void, Never>?
    init() throws {
        account = try PersonalJournalFixtures.session(); page = try PersonalJournalFixtures.page()
        entries = [page.query.date: page.entries[0]]
    }
    func configure(lostReply: Bool = false, unknownReceipt: Bool = false, readError: Bool = false, account: HouseholdSession? = nil) {
        self.lostReply = lostReply; self.unknownReceipt = unknownReceipt; self.readError = readError
        if let account { self.account = account }
    }
    func hold() { held = true }
    func waitHeld() async throws {
        for _ in 0..<200 { if continuation != nil { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw HouseholdFailure.uncertain
    }
    func release() { continuation?.resume(); continuation = nil }
    func session() async throws -> HouseholdSession { account }
    func read(date: String) async throws -> PersonalJournalPage {
        reads.append(date)
        let result = PersonalJournalPage(version: 1, generatedAt: page.generatedAt, scope: page.scope, interpretation: page.interpretation,
            currentTimeZone: page.currentTimeZone, query: .init(date: date),
            entries: [entries[date] ?? .init(date: date, revision: nil, timeZone: nil, record: nil)])
        if held { held = false; await withCheckedContinuation { continuation = $0 } }
        if readError { throw HouseholdFailure.uncertain }
        return result
    }
    func write(_ input: PersonalJournalWrite) async throws -> PersonalJournalResult {
        writes.append(input)
        guard input.expectedRevision == entries[input.date]?.revision else { throw HouseholdFailure.conflict }
        let receipt = PersonalJournalReceipt(requestId: input.requestId, date: input.date, revision: UUID().uuidString.lowercased(),
            timeZone: input.expectedTimeZone, savedAt: page.generatedAt, outcome: input.fields == nil ? "deleted" : "saved")
        receipts[input.requestId] = receipt
        entries[input.date] = .init(date: input.date, revision: receipt.revision, timeZone: receipt.timeZone, record: input.fields.map {
            .init(date: input.date, timeZone: receipt.timeZone, createdAt: page.generatedAt, updatedAt: page.generatedAt, fields: $0)
        })
        if lostReply { throw HouseholdFailure.uncertain }
        return result(receipt)
    }
    func receipt(requestId: String) async throws -> PersonalJournalResult { result(unknownReceipt ? nil : receipts[requestId]) }
    func replaceSavedNote(_ note: String) {
        guard let entry = entries[page.query.date], let record = entry.record else { return }
        var fields = record.fields; fields.notes = note
        entries[entry.date] = .init(date: entry.date, revision: UUID().uuidString.lowercased(), timeZone: entry.timeZone,
            record: .init(date: entry.date, timeZone: record.timeZone, createdAt: record.createdAt, updatedAt: page.generatedAt, fields: fields))
    }
    private func result(_ receipt: PersonalJournalReceipt?) -> PersonalJournalResult {
        .init(version: 1, generatedAt: page.generatedAt, scope: page.scope, interpretation: page.interpretation, receipt: receipt)
    }
}

@MainActor final class PersonalJournalWorkspaceTests: XCTestCase {
    private func workspace(_ server: PersonalJournalTestServer) throws -> PersonalJournalWorkspace {
        let now = Date(timeIntervalSince1970: Double(try PersonalJournalFixtures.page().generatedAt) / 1000)
        return .init(connection: try PersonalJournalFixtures.connection(), client: server, now: { now })
    }
    private func change(_ model: PersonalJournalWorkspace, note: String = "A private new note") throws {
        var draft = try XCTUnwrap(model.draft); draft.restfulness = 5; draft.comfort = "comfortable"; draft.notes = note; model.edit(draft)
    }
    func testEmptyEntryRequiresExplicitAnswersAndSavedEditsStayUnsavedUntilCommit() async throws {
        let server = try PersonalJournalTestServer(), model = try workspace(server)
        XCTAssertNil(model.page)
        await model.open(date: "2026-11-09")
        XCTAssertNil(model.draft?.restfulness); XCTAssertNil(model.draft?.comfort); XCTAssertFalse(model.canSave)
        try change(model); XCTAssertTrue(model.canSave); XCTAssertTrue(model.entryStatus.contains("Unsaved"))
        await model.save(); XCTAssertEqual(model.draft?.restfulness, 5); XCTAssertFalse(model.dirty); XCTAssertNil(model.pending)
        XCTAssertTrue(model.entryStatus.contains("saved check-in"))
        try change(model, note: "Another draft"); XCTAssertTrue(model.entryStatus.contains("Unsaved"))
        let writes = await server.writes; XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes[0].fields?.notes, "A private new note")
    }
    func testLostWriteReplyReconcilesWithoutResendingAndReadsNewerEntry() async throws {
        let server = try PersonalJournalTestServer(), model = try workspace(server)
        await model.open(date: "2026-11-10"); try change(model); await server.configure(lostReply: true)
        await model.save(); XCTAssertNotNil(model.pending); XCTAssertFalse(model.editable); XCTAssertNotNil(model.error)
        await model.save(); await server.replaceSavedNote("A later saved entry")
        await model.reconcile()
        XCTAssertNil(model.pending); XCTAssertEqual(model.draft?.notes, "A later saved entry")
        XCTAssertTrue(model.notice?.contains("changed again") == true)
        let writes = await server.writes; XCTAssertEqual(writes.count, 1)
    }
    func testUnknownReceiptBlocksAnotherWriteUntilExplicitReopen() async throws {
        let server = try PersonalJournalTestServer(), model = try workspace(server)
        await model.open(date: "2026-11-10"); try change(model)
        await server.configure(lostReply: true, unknownReceipt: true); await model.save(); await model.reconcile()
        XCTAssertNotNil(model.pending); XCTAssertFalse(model.editable)
        await model.open(date: "2026-11-09"); XCTAssertEqual(model.selected?.date, "2026-11-10")
        await model.open(date: "2026-11-10", discardDraft: true); XCTAssertNil(model.pending)
        XCTAssertEqual(model.draft?.notes, "A private new note")
        let writes = await server.writes; XCTAssertEqual(writes.count, 1)
    }
    func testDeletionRetainsTombstoneAndDoesNotResurrectThroughARead() async throws {
        let server = try PersonalJournalTestServer(), model = try workspace(server)
        await model.open(date: "2026-11-10"); await model.save(remove: true)
        XCTAssertNil(model.selected?.record); XCTAssertNotNil(model.selected?.revision); XCTAssertEqual(model.draft?.notes, "")
        await model.open(date: "2026-11-10")
        XCTAssertNil(model.selected?.record)
        let writes = await server.writes; XCTAssertEqual(writes.count, 1); XCTAssertNil(writes[0].fields)
    }
    func testInvalidOptionalContextExplainsWhySavingIsUnavailable() async throws {
        let server = try PersonalJournalTestServer(), model = try workspace(server)
        await model.open(date: "2026-11-10")
        var draft = try XCTUnwrap(model.draft)
        draft.context.caffeine.status = "yes"; draft.context.caffeine.amount = "-1"; model.edit(draft)
        XCTAssertFalse(model.canSave); XCTAssertTrue(model.validationIssue?.contains("nonnegative") == true)
        draft.context.caffeine.amount = ""; model.edit(draft)
        XCTAssertTrue(model.canSave); XCTAssertNil(model.validationIssue)
        draft.notes = String(repeating: "a", count: 501); model.edit(draft)
        XCTAssertFalse(model.canSave); XCTAssertTrue(model.validationIssue?.contains("500") == true)
    }
    func testBackgroundAndChangedAccountRejectLatePrivateReplies() async throws {
        for background in [true, false] {
            let server = try PersonalJournalTestServer(), model = try workspace(server)
            await server.hold()
            let opening = Task { await model.open(date: "2026-11-10") }; try await server.waitHeld()
            if background { model.suspend() }
            else {
                let changed: HouseholdSession = try PersonalHistoryFixtures.changed(PersonalJournalFixtures.session()) { $0["sessionRevision"] = 2 }
                await server.configure(account: changed)
            }
            await server.release(); await opening.value
            XCTAssertNil(model.page); XCTAssertNil(model.draft); XCTAssertFalse(model.busy)
            if !background { XCTAssertTrue(model.isInvalidated) }
        }
    }
    func testDraftIsPreservedForDateReviewAndClearedWhenPermissionWithdrawn() async throws {
        let server = try PersonalJournalTestServer(), model = try workspace(server)
        await model.open(date: "2026-11-10"); try change(model)
        await model.open(date: "2026-11-09"); XCTAssertEqual(model.selected?.date, "2026-11-10"); XCTAssertTrue(model.dirty)
        let changed: HouseholdSession = try PersonalHistoryFixtures.changed(PersonalJournalFixtures.session()) {
            var capabilities = $0["capabilities"] as! [String: Any]; capabilities["personalJournal"] = false; $0["capabilities"] = capabilities
        }
        await server.configure(account: changed); await model.checkAccess()
        XCTAssertNil(model.draft); XCTAssertNil(model.page); XCTAssertTrue(model.isInvalidated)
        let writes = await server.writes; XCTAssertTrue(writes.isEmpty)
    }
}
