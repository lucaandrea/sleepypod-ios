import XCTest
@testable import Sleepypod

@MainActor final class MorningJournalContextTests: XCTestCase {
    private let zone = "America/Los_Angeles"
    private let wakeDate = "2026-11-01"
    private var now: Date { Date(timeIntervalSince1970: 1_793_563_200) }
    private func instant(_ value: String) throws -> Double {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value)).timeIntervalSince1970 * 1000
    }
    func testCoreProducedFixtureRetainsCountsMissingnessAndDistinctSources() throws {
        let example = try MorningJournalExample.load(context: true)
        XCTAssertTrue(example.synthetic)
        try example.page.validate(side: .left, date: wakeDate, days: 30)
        XCTAssertEqual(example.page.contextVersion, 1)
        XCTAssertEqual(example.page.entries.count, 10)
        let comparisons = try XCTUnwrap(example.page.contextPatterns?.cohorts.first?.comparisons)
        let exercise = try XCTUnwrap(comparisons.first { $0.id == "exercise-time" })
        XCTAssertEqual(exercise.withCount, 5); XCTAssertEqual(exercise.withoutCount, 5)
        XCTAssertEqual(exercise.warmRateDifferencePoints, 100)
        XCTAssertNil(comparisons.first { $0.id == "alcohol-time" }?.warmRateDifferencePoints)
        XCTAssertEqual(example.page.selected.record?.fields.context?.alcohol.status, "not_logged")
    }
    func testClockGapsFoldsQuarterHourZonesAndRetainedOccurrence() throws {
        XCTAssertTrue(MorningJournalContextClock.candidates("2026-03-08T02:30", timeZone: zone).isEmpty)
        XCTAssertTrue(MorningJournalContextClock.candidates("2026-02-30T12:00", timeZone: zone).isEmpty)
        XCTAssertTrue(MorningJournalContextClock.candidates("2026-11-01T01:30", timeZone: "Unknown/Zone").isEmpty)
        let fold = MorningJournalContextClock.candidates("2026-11-01T01:30", timeZone: zone)
        XCTAssertEqual(fold, try [instant("2026-11-01T08:30:00Z"), instant("2026-11-01T09:30:00Z")])
        var time = MorningJournalContextDraft.Time(timeZone: zone); time.wall = "2026-11-01T01:30"
        XCTAssertThrowsError(try time.resolved(timeZone: zone))
        time.occurrence = fold[1]; XCTAssertEqual(try time.resolved(timeZone: zone), fold[1])
        let saved = MorningJournalContextDraft.Time(fold[1] + 15_000, timeZone: zone)
        XCTAssertEqual(try saved.resolved(timeZone: zone), fold[1])
        let halfHour = MorningJournalContextClock.candidates("2026-04-05T01:45", timeZone: "Australia/Lord_Howe")
        XCTAssertEqual(halfHour.count, 2); XCTAssertEqual(halfHour.last! - halfHour.first!, 1_800_000)
        XCTAssertEqual(MorningJournalContextClock.candidates("2026-11-01T12:00", timeZone: "Asia/Kathmandu"), try [instant("2026-11-01T06:15:00Z")])
    }
    func testUnknownNoneBlankAndExplicitZeroRemainDistinct() throws {
        var draft = MorningJournalContextDraft(fields: .init(), timeZone: zone)
        XCTAssertEqual(draft.caffeine.status, "not_logged")
        let unknown = try draft.fields(from: .init(), date: wakeDate, timeZone: zone, now: now)
        draft.caffeine.status = "none"
        let none = try draft.fields(from: .init(), date: wakeDate, timeZone: zone, now: now)
        draft.caffeine.status = "yes"
        let blank = try draft.fields(from: .init(), date: wakeDate, timeZone: zone, now: now)
        draft.caffeine.amount = "0"
        let zero = try draft.fields(from: .init(), date: wakeDate, timeZone: zone, now: now)
        XCTAssertNotEqual(unknown, none); XCTAssertNotEqual(none, blank); XCTAssertNotEqual(blank, zero)
        XCTAssertNil(blank.context?.caffeine.amount); XCTAssertEqual(zero.context?.caffeine.amount, 0)
        XCTAssertTrue(zero.caffeine); XCTAssertFalse(unknown.caffeine)
        draft.alcohol.status = "yes"; draft.alcohol.amount = "1,5"
        XCTAssertEqual(try draft.fields(from: .init(), date: wakeDate, timeZone: zone, now: now, locale: Locale(identifier: "it_IT")).context?.alcohol.amount, 1.5)
    }
    func testDraftRejectsMalformedUnitsAmountsFutureAndOutOfWindowTimes() throws {
        var draft = MorningJournalContextDraft(fields: .init(), timeZone: zone)
        draft.caffeine.status = "yes"
        for amount in ["-1", "NaN", "Infinity", "12mg", "10001"] {
            draft.caffeine.amount = amount
            XCTAssertThrowsError(try draft.fields(from: .init(), date: wakeDate, timeZone: zone, now: now), amount)
        }
        draft.caffeine.amount = ""
        draft.caffeine.time.wall = "2026-10-30T23:59"
        XCTAssertThrowsError(try draft.fields(from: .init(), date: wakeDate, timeZone: zone, now: now))
        draft.caffeine.time.wall = "2026-11-01T23:59"
        XCTAssertThrowsError(try draft.fields(from: .init(), date: wakeDate, timeZone: zone, now: now))
        draft.caffeine.time.wall = ""
        XCTAssertThrowsError(try draft.fields(from: .init(), date: "2026-11-03", timeZone: zone, now: now))
        var fields = try draft.fields(from: .init(), date: wakeDate, timeZone: zone, now: now)
        fields.caffeine = false; XCTAssertThrowsError(try fields.validate())
        var context = MorningJournalContext(); context.caffeine = .init(status: "yes", unit: "minutes")
        XCTAssertThrowsError(try context.validate())
    }
    func testExpectedClockIsOnlyEncodedForCapableServerAndRawContextIsTyped() throws {
        let example = try MorningJournalExample.load(context: true)
        let write = MorningJournalWrite(side: .left, date: wakeDate, expectedRevision: example.page.selected.revision,
            fields: example.page.selected.record?.fields, expectedTimeZone: zone)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(write)) as? [String: Any])
        XCTAssertEqual(body["expectedTimeZone"] as? String, zone)
        XCTAssertEqual(((body["fields"] as? [String: Any])?["context"] as? [String: Any])?["version"] as? Int, 1)
        var legacy = write; legacy.expectedTimeZone = nil
        let older = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertNil(older["expectedTimeZone"])
    }
    func testContextPatternRejectsForgedCountsDifferencesAndSources() throws {
        let page = try MorningJournalExample.load(context: true).page
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
        for field in ["withCount", "warmRateDifferencePoints", "withWarmCount"] {
            var body = original
            var patterns = try XCTUnwrap(body["contextPatterns"] as? [String: Any])
            var cohorts = try XCTUnwrap(patterns["cohorts"] as? [[String: Any]])
            var comparisons = try XCTUnwrap(cohorts[0]["comparisons"] as? [[String: Any]])
            comparisons[0][field] = 999
            cohorts[0]["comparisons"] = comparisons; patterns["cohorts"] = cohorts; body["contextPatterns"] = patterns
            let changed = try JSONDecoder().decode(MorningJournalPage.self, from: JSONSerialization.data(withJSONObject: body))
            XCTAssertThrowsError(try changed.validate(side: .left, date: wakeDate, days: 30), field)
        }
        var mismatched = page; mismatched.contextVersion = nil
        XCTAssertThrowsError(try mismatched.validate(side: .left, date: wakeDate, days: 30))
    }
    func testContextDraftSurvivesSideChangesAndResetsAtOwnerBoundary() async throws {
        let model = MorningJournalWorkspace(); model.configure(client: DemoMorningJournalClient(scenario: "context"), side: .left)
        await model.load(); XCTAssertNil(model.error)
        var draft = try XCTUnwrap(model.draft?.contextDraft); draft.caffeine.amount = "175."
        model.editContext(draft); XCTAssertTrue(model.hasUnsaved)
        await model.load(side: .right); XCTAssertEqual(model.draft?.contextDraft?.caffeine.status, "not_logged")
        await model.load(side: .left); XCTAssertEqual(model.draft?.contextDraft?.caffeine.amount, "175.")
        let saved = await model.save(); XCTAssertTrue(saved, model.error ?? "")
        XCTAssertEqual(model.draft?.original.record?.fields.context?.caffeine.amount, 175)
        model.configure(client: DemoMorningJournalClient(), side: .right)
        XCTAssertNil(model.draft); XCTAssertTrue(model.drafts.isEmpty)
    }
    func testChangedClockRequiresExplicitChoiceBeforeReinterpretingDraft() async throws {
        let model = MorningJournalWorkspace(); model.configure(client: DemoMorningJournalClient(scenario: "context-zone"), side: .left)
        await model.load()
        var draft = try XCTUnwrap(model.draft?.contextDraft)
        draft.caffeine.status = "yes"; draft.caffeine.time.wall = "2026-10-31T14:00"
        model.editContext(draft)
        let first = await model.save(); XCTAssertFalse(first)
        await model.load(); XCTAssertTrue(model.draft?.timeZoneConflict == true); XCTAssertFalse(model.canSave)
        XCTAssertEqual(model.draft?.contextTimeZone, zone)
        XCTAssertEqual(model.draft?.contextDraft?.caffeine.time.wall, "2026-10-31T14:00")
        model.resolve(keepDraft: true); XCTAssertTrue(model.canSave)
        XCTAssertEqual(model.draft?.contextTimeZone, "America/New_York")
        let saved = await model.save(); XCTAssertTrue(saved, model.error ?? "")
        XCTAssertEqual(model.draft?.original.record?.fields.context?.caffeine.lastAt, try instant("2026-10-31T18:00:00Z"))
    }
    func testUncertainSaveKeepsNewerContextAndNeverAutomaticallyReplays() async throws {
        let model = MorningJournalWorkspace(); model.configure(client: DemoMorningJournalClient(scenario: "context-lost-save"), side: .left)
        await model.load()
        var draft = try XCTUnwrap(model.draft?.contextDraft); draft.caffeine.amount = "150"
        model.editContext(draft); let first = await model.save(); XCTAssertFalse(first)
        draft.caffeine.amount = "170"; model.editContext(draft)
        let blocked = await model.save(); XCTAssertFalse(blocked)
        await model.load()
        XCTAssertEqual(model.draft?.original.record?.fields.context?.caffeine.amount, 150)
        XCTAssertEqual(model.draft?.contextDraft?.caffeine.amount, "170")
        XCTAssertTrue(model.hasUnsaved); XCTAssertTrue(model.canSave)
        XCTAssertEqual(model.notice, "The earlier change is saved. Your newer draft is kept for review; nothing was sent again.")
    }
    func testConflictingSavedDetailsRemainValidAndSeparateFromDraft() async throws {
        let model = MorningJournalWorkspace(); model.configure(client: DemoMorningJournalClient(scenario: "context-conflict"), side: .left)
        await model.load()
        var draft = try XCTUnwrap(model.draft?.contextDraft); draft.caffeine.amount = "175"
        model.editContext(draft); let saved = await model.save(); XCTAssertFalse(saved)
        await model.load(); XCTAssertNil(model.error)
        let comparison = try XCTUnwrap(model.draft?.comparison?.record)
        try comparison.validate()
        XCTAssertEqual(comparison.fields.context?.caffeine.status, "not_logged")
        XCTAssertNil(comparison.fields.context?.caffeine.amount)
        XCTAssertEqual(comparison.fields.context?.alcohol.amount, 0)
        XCTAssertEqual(comparison.fields.context?.exercise.amount, 42)
        XCTAssertNotNil(comparison.fields.context?.lastMealAt)
        XCTAssertEqual(model.draft?.contextDraft?.caffeine.amount, "175")
        model.resolve(keepDraft: false)
        XCTAssertEqual(model.draft?.contextDraft?.caffeine.status, "not_logged")
        XCTAssertFalse(model.hasUnsaved)
    }
}
