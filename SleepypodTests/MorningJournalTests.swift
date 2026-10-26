import XCTest
@testable import Sleepypod

@MainActor final class MorningJournalTests: XCTestCase {
    func testSourceFixtureCalendarDaysAndSeparatePresenceCohorts() throws {
        let example = try MorningJournalExample.load(); XCTAssertTrue(example.synthetic)
        try example.page.validate(side: .left, date: "2026-10-25", days: 30)
        XCTAssertEqual(example.page.patterns.cohorts.map(\.source), ["sleepypod", "free-sleep"])
        XCTAssertEqual(example.page.patterns.cohorts[0].associations.first?.presenceDifferenceMinutes, -40)
        XCTAssertFalse(MorningJournalDates.valid("2026-02-30")); XCTAssertFalse(MorningJournalDates.valid("1969-12-31"))
        XCTAssertNil(MorningJournalDates.localDate("2011-12-30", timeZone: "Pacific/Apia"))
        let spring = try XCTUnwrap(MorningJournalDates.localDate("2026-03-08", timeZone: "America/Los_Angeles"))
        let next = try XCTUnwrap(MorningJournalDates.localDate("2026-03-09", timeZone: "America/Los_Angeles"))
        XCTAssertEqual(next.timeIntervalSince(spring), 23 * 3600)
        XCTAssertEqual(MorningJournalDates.shift("2026-03-09", days: -1), "2026-03-08")
        XCTAssertThrowsError(try example.page.validate(side: .right, date: nil, days: 30))
        XCTAssertThrowsError(try example.page.validate(side: .left, date: nil, days: 7))
    }
    func testTrimmedUTF16LimitAndExplicitNullMutationFields() throws {
        var fields = MorningJournalFields(); fields.notes = String(repeating: "🌙", count: 250)
        XCTAssertNoThrow(try fields.validate()); fields.notes += "🌙"; XCTAssertThrowsError(try fields.validate())
        fields.notes = "  My private note\n"; XCTAssertEqual(fields.normalized.notes, "My private note")
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MorningJournalWrite(side: .left, date: "2026-10-25", expectedRevision: nil, fields: nil))) as! [String: Any]
        XCTAssertTrue(body["fields"] is NSNull); XCTAssertTrue(body["expectedRevision"] is NSNull)
        XCTAssertEqual(Set(body.keys), ["side", "date", "fields", "expectedRevision"])
    }
    func testDraftsRemainSeparateAcrossSideAndWakeDateAndClearForNewOwner() async throws {
        let model = MorningJournalWorkspace(); model.configure(client: DemoMorningJournalClient(scenario: "example"), side: .left); await model.load()
        var fields = try XCTUnwrap(model.draft?.fields); fields.notes = "Left draft"; model.edit(fields)
        await model.load(side: .right); XCTAssertEqual(model.draft?.fields.notes, "")
        fields.notes = "Right draft"; model.edit(fields); await model.load(side: .left, date: "2026-10-24")
        XCTAssertEqual(model.draft?.fields.notes, ""); await model.load(date: "2026-10-25")
        XCTAssertEqual(model.draft?.fields.notes, "Left draft")
        await model.load(side: .right); XCTAssertEqual(model.draft?.fields.notes, "Right draft")
        model.configure(client: DemoMorningJournalClient(), side: .left); XCTAssertTrue(model.drafts.isEmpty); XCTAssertNil(model.page)
    }
    func testConflictKeepsDraftAndRequiresExplicitSavedComparisonBeforeReplacement() async throws {
        let client = JournalTestClient(scenario: "conflict"), model = MorningJournalWorkspace()
        model.configure(client: client, side: .left); await model.load()
        var fields = try XCTUnwrap(model.draft?.fields); fields.notes = "My retained draft"; model.edit(fields)
        let first = await model.save(); XCTAssertFalse(first); XCTAssertFalse(model.canSave)
        await model.load(); XCTAssertEqual(model.draft?.fields.notes, "My retained draft")
        XCTAssertEqual(model.draft?.comparison?.record?.fields.notes, "Synthetic edit from another device."); XCTAssertFalse(model.canSave)
        let blocked = await model.save(); XCTAssertFalse(blocked); var count = await client.writeCount; XCTAssertEqual(count, 1)
        model.resolve(keepDraft: true); XCTAssertTrue(model.canSave)
        let saved = await model.save(); XCTAssertTrue(saved); XCTAssertEqual(model.draft?.original.record?.fields.notes, "My retained draft")
        count = await client.writeCount; XCTAssertEqual(count, 2)
    }
    func testLostSaveReadsMatchingRevisionWithoutSubmittingAgain() async throws {
        let client = JournalTestClient(scenario: "lost-save"), model = MorningJournalWorkspace()
        model.configure(client: client, side: .left); await model.load()
        var fields = try XCTUnwrap(model.draft?.fields); fields.notes = "Read this back"; model.edit(fields)
        let saved = await model.save(); XCTAssertFalse(saved); XCTAssertTrue(model.draft?.needsReadback == true)
        let retry = await model.save(); XCTAssertFalse(retry)
        await model.load(); XCTAssertTrue(model.canSave); XCTAssertFalse(model.hasUnsaved)
        XCTAssertEqual(model.draft?.original.record?.fields.notes, "Read this back")
        let count = await client.writeCount; XCTAssertEqual(count, 1)
        XCTAssertTrue(model.notice?.contains("Nothing was sent again") == true)
    }
    func testLostSaveAndDeleteReadbackKeepEditsMadeAfterUncertainResponse() async throws {
        for deleting in [false, true] {
            let client = JournalTestClient(scenario: "lost-save"), model = MorningJournalWorkspace()
            model.configure(client: client, side: .left); await model.load()
            var fields = try XCTUnwrap(model.draft?.fields); fields.notes = "First draft"; model.edit(fields)
            let saved = await model.save(delete: deleting); XCTAssertFalse(saved)
            fields.notes = "Newer unsaved draft"; model.edit(fields); await model.load()
            XCTAssertEqual(model.draft?.fields.notes, "Newer unsaved draft")
            XCTAssertEqual(model.draft?.original.record?.fields.notes, deleting ? nil : "First draft")
            XCTAssertTrue(model.hasUnsaved); XCTAssertTrue(model.canSave)
            let count = await client.writeCount; XCTAssertEqual(count, 1)
        }
    }
    func testFailedReadbackRetainsUncertainDraftAndBlocksWrite() async throws {
        let client = JournalTestClient(scenario: "lost-save"), model = MorningJournalWorkspace()
        model.configure(client: client, side: .left); await model.load()
        var fields = try XCTUnwrap(model.draft?.fields); fields.notes = "Retain while offline"; model.edit(fields)
        _ = await model.save(); await client.failRead(); await model.load()
        XCTAssertNil(model.page); XCTAssertTrue(model.draft?.needsReadback == true); XCTAssertEqual(model.draft?.fields.notes, fields.notes)
        let retry = await model.save(); XCTAssertFalse(retry); let count = await client.writeCount; XCTAssertEqual(count, 1)
    }
    func testDeleteRetainsTombstoneAndStaleEntryCannotRecreateIt() async throws {
        let client = DemoMorningJournalClient(scenario: "example"), model = MorningJournalWorkspace()
        model.configure(client: client, side: .left); await model.load(); let old = try XCTUnwrap(model.draft?.original)
        let deleted = await model.save(delete: true); XCTAssertTrue(deleted); XCTAssertNil(model.draft?.original.record)
        XCTAssertNotNil(model.draft?.original.revision); XCTAssertNotEqual(model.draft?.original.revision, old.revision)
        do { _ = try await client.write(.init(side: .left, date: old.date, expectedRevision: old.revision, fields: old.record?.fields)); XCTFail("Stale recreation must fail") }
        catch MorningJournalFailure.conflict {} catch { XCTFail("Unexpected failure") }
    }
    func testLateSaveCannotPublishIntoAnotherConnection() async throws {
        let client = JournalTestClient(scenario: "example"), model = MorningJournalWorkspace()
        model.configure(client: client, side: .left); await model.load(); await client.holdWrite()
        let operation = Task { await model.save() }; await client.waitUntilHeld()
        model.configure(client: DemoMorningJournalClient(), side: .right); await client.release()
        let saved = await operation.value; XCTAssertFalse(saved); XCTAssertNil(model.page); XCTAssertTrue(model.drafts.isEmpty); XCTAssertFalse(model.busy)
    }
    func testInterruptedSaveRequiresReadbackAndSavedChoiceCanDiscardDraft() async throws {
        let client = JournalTestClient(scenario: "conflict"), model = MorningJournalWorkspace()
        model.configure(client: client, side: .left); await model.load()
        var fields = try XCTUnwrap(model.draft?.fields); fields.notes = "Discard this draft"; model.edit(fields)
        await client.holdWrite(); let operation = Task { await model.save() }; await client.waitUntilHeld()
        model.invalidate(); await client.release(); _ = await operation.value
        XCTAssertTrue(model.draft?.needsReadback == true); await model.load(); XCTAssertNotNil(model.draft?.comparison)
        model.resolve(keepDraft: false); XCTAssertEqual(model.draft?.fields.notes, "Synthetic edit from another device.")
        XCTAssertFalse(model.hasUnsaved); XCTAssertTrue(model.canSave)
    }
}

private actor JournalTestClient: MorningJournalClient {
    let delegate: DemoMorningJournalClient
    private var readFailure = false
    private var pauseWrite = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var writeCount = 0
    init(scenario: String) { delegate = DemoMorningJournalClient(scenario: scenario) }
    func available() async throws { try await delegate.available() }
    func read(side: Side, date: String?, days: Int) async throws -> MorningJournalPage {
        if readFailure { readFailure = false; throw URLError(.notConnectedToInternet) }
        return try await delegate.read(side: side, date: date, days: days)
    }
    func write(_ input: MorningJournalWrite) async throws -> MorningJournalSelection {
        writeCount += 1
        if pauseWrite { pauseWrite = false; await withCheckedContinuation { continuation = $0 } }
        return try await delegate.write(input)
    }
    func failRead() { readFailure = true }
    func holdWrite() { pauseWrite = true }
    func waitUntilHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
