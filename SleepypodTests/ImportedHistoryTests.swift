import XCTest
@testable import Sleepypod

@MainActor final class ImportedHistoryTests: XCTestCase {
    private func example() throws -> ImportedHistoryExample { try ImportedHistoryExample.load() }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func query(_ kind: ImportedHistoryKind = .presence) throws -> ImportedHistoryQuery {
        try .days(snapshot: XCTUnwrap(example().status.snapshot), side: .left, kind: kind,
                  from: date("2026-10-20T12:00:00Z"), through: date("2026-10-26T12:00:00Z"))
    }
    func testArchiveDefinitionsAndMissingValuesStaySourceSeparated() throws {
        let source = try example(); XCTAssertTrue(source.synthetic)
        try source.status.validate(); try source.notImported.validate()
        XCTAssertFalse(source.status.semantics.automationInput); XCTAssertFalse(source.status.semantics.previewEvidence)
        for page in [source.pages.presence, source.pages.vitals, source.pages.movement] { try page.validate(for: query(page.kind)) }
        if case .vitals(let value) = source.pages.vitals.records[1] {
            XCTAssertNil(value.heartRateBpm); XCTAssertEqual(value.hrvEstimateMs, 39); XCTAssertNil(value.breathingRatePerMinute)
            XCTAssertEqual(ImportedHistoryDisplay.number(value.heartRateBpm), "Unavailable")
        } else { XCTFail("Wrong record kind") }
        var semantics = source.status.semantics; semantics.previewEvidence = true; XCTAssertThrowsError(try semantics.validate())
    }
    func testInclusiveSourceDaysUseCalendarMidnightsAcrossDST() throws {
        let snapshot = try XCTUnwrap(example().status.snapshot)
        let spring = date("2026-03-08T12:00:00Z"), fall = date("2026-11-01T12:00:00Z")
        let forward = try ImportedHistoryQuery.days(snapshot: snapshot, side: .right, kind: .vitals, from: spring, through: spring)
        let backward = try ImportedHistoryQuery.days(snapshot: snapshot, side: .left, kind: .presence, from: fall, through: fall)
        XCTAssertEqual(forward.start, date("2026-03-08T08:00:00Z")); XCTAssertEqual(forward.end, date("2026-03-09T07:00:00Z"))
        XCTAssertEqual(forward.end.timeIntervalSince(forward.start), 23 * 3600)
        XCTAssertEqual(backward.end.timeIntervalSince(backward.start), 25 * 3600)
    }
    func testRangeAndCursorBoundsAreValidatedBeforeDispatch() throws {
        var value = try query(); value.end = value.start; XCTAssertThrowsError(try value.validate())
        value.end = value.start.addingTimeInterval(90 * 86400 + 1); XCTAssertThrowsError(try value.validate())
        value.end = value.start.addingTimeInterval(90 * 86400); XCTAssertNoThrow(try value.validate())
        value.cursor = ""; XCTAssertThrowsError(try value.validate()); value.cursor = "one&two+three"; XCTAssertNoThrow(try value.validate())
        XCTAssertEqual(value.parameters["cursor"], "one&two+three")
        value.limit = 501; XCTAssertThrowsError(try value.validate())
    }
    func testMismatchedSourceSideRangeOrderAndCursorAreRejected() throws {
        let source = try example(), expected = try query(.vitals)
        var page = source.pages.vitals
        page.snapshotId = String(repeating: "f", count: 64); XCTAssertThrowsError(try page.validate(for: expected))
        page = source.pages.vitals; page.side = .right; XCTAssertThrowsError(try page.validate(for: expected))
        page = source.pages.vitals; page.records.reverse(); XCTAssertThrowsError(try page.validate(for: expected))
        page = source.pages.vitals; page.records.append(page.records[0]); XCTAssertThrowsError(try page.validate(for: expected))
        var narrow = expected; narrow.start = date("2026-10-25T05:35:00Z")
        XCTAssertThrowsError(try source.pages.vitals.validate(for: narrow))
        var repeated = expected; repeated.cursor = "same"; page = source.pages.vitals; page.nextCursor = "same"
        XCTAssertThrowsError(try page.validate(for: repeated))
    }
    func testPresenceClaimsAreIndependentAndValidatedWithoutRepair() throws {
        let source = try example(), original = source.detail.record
        var detail = source.detail
        try detail.validate(snapshotID: source.detail.snapshotId, original: original)
        XCTAssertEqual(detail.record.reportedDurationSeconds, 27900); XCTAssertEqual(detail.present.coveredSeconds, 28200)
        detail.absent = detail.present // Contradictory claims remain independent, not silently repaired.
        XCTAssertNoThrow(try detail.validate(snapshotID: detail.snapshotId, original: original))
        detail.present.coveredSeconds = 0; XCTAssertThrowsError(try detail.validate(snapshotID: detail.snapshotId, original: original))
        detail = source.detail; detail.absent = .init(status: .unavailable, intervals: nil, coveredSeconds: 0)
        XCTAssertThrowsError(try detail.validate(snapshotID: detail.snapshotId, original: original))
        detail.absent.coveredSeconds = nil; XCTAssertNoThrow(try detail.validate(snapshotID: detail.snapshotId, original: original))
        detail.present.intervals = [[original.enteredBedAt - 1, original.leftBedAt]]
        XCTAssertThrowsError(try detail.validate(snapshotID: detail.snapshotId, original: original))
    }
    func testPagingRetainsNewestOrderAndClearsOnFilterChange() async throws {
        let model = ImportedHistoryWorkspace(); model.configure(client: DemoImportedHistoryClient(scenario: "example")); await model.loadStatus()
        XCTAssertTrue(model.records.isEmpty, "Loading provenance must not silently request record pages")
        let range = try query()
        await model.apply(side: .left, kind: .presence, start: range.start, end: range.end.addingTimeInterval(-1))
        XCTAssertEqual(model.records.map(\.sourceID), [2]); XCTAssertTrue(model.canLoadMore)
        await model.loadMore(); XCTAssertEqual(model.records.map(\.sourceID), [2, 1]); XCTAssertFalse(model.canLoadMore)
        model.clearRecords(); XCTAssertNil(model.applied); XCTAssertTrue(model.records.isEmpty)
        await model.apply(side: .right, kind: .presence, start: range.start, end: range.end.addingTimeInterval(-1))
        XCTAssertEqual(model.applied?.side, .right); XCTAssertTrue(model.records.isEmpty)
    }
    func testChangedSnapshotDiscardsAllRowsAndRequiresFreshProvenance() async throws {
        let client = HistoryTestClient(example: try example()), model = ImportedHistoryWorkspace()
        model.configure(client: client); await model.loadStatus(); let range = try query()
        await model.apply(side: .left, kind: .presence, start: range.start, end: range.end.addingTimeInterval(-1))
        await client.failNext(.changed); await model.loadMore()
        XCTAssertNil(model.status); XCTAssertNil(model.applied); XCTAssertNil(model.nextCursor); XCTAssertTrue(model.records.isEmpty)
        await model.loadMore(); let calls = await client.pageCalls; XCTAssertEqual(calls, 2)
        await model.loadStatus(); XCTAssertNotNil(model.status); XCTAssertNil(model.error)
    }
    func testFailedNextPageKeepsExplicitlyStaleRowsWithoutAutomaticRetry() async throws {
        let client = HistoryTestClient(example: try example()), model = ImportedHistoryWorkspace()
        model.configure(client: client); await model.loadStatus(); let range = try query()
        await model.apply(side: .left, kind: .presence, start: range.start, end: range.end.addingTimeInterval(-1))
        await client.failNext(.unavailable("Offline")); await model.loadMore()
        XCTAssertEqual(model.records.map(\.sourceID), [2]); XCTAssertTrue(model.stale); XCTAssertFalse(model.canLoadMore)
        await model.loadMore(); let calls = await client.pageCalls; XCTAssertEqual(calls, 2)
        await model.apply(side: .left, kind: .presence, start: range.start, end: range.end.addingTimeInterval(-1))
        XCTAssertFalse(model.stale); XCTAssertNil(model.error)
    }
    func testRepeatedRowsCannotBeAppended() async throws {
        let source = try example(), client = HistoryTestClient(example: source), model = ImportedHistoryWorkspace()
        model.configure(client: client); await model.loadStatus(); let range = try query()
        await model.apply(side: .left, kind: .presence, start: range.start, end: range.end.addingTimeInterval(-1))
        var repeated = source.pages.presence; repeated.nextCursor = "another-cursor"
        await client.overrideNext(repeated); await model.loadMore()
        XCTAssertEqual(model.records.count, 1); XCTAssertTrue(model.stale); XCTAssertTrue(model.error?.contains("repeated") == true)
    }
    func testInvalidatedOwnerReadCannotPublishIntoNewConnection() async throws {
        let client = HistoryTestClient(example: try example()), model = ImportedHistoryWorkspace()
        model.configure(client: client); await model.loadStatus(); let range = try query(); await client.holdNextPage()
        let pending = Task { await model.apply(side: .left, kind: .presence, start: range.start, end: range.end.addingTimeInterval(-1)) }
        await client.waitUntilHeld(); model.configure(client: DemoImportedHistoryClient()); await client.release()
        await pending.value
        XCTAssertNil(model.status); XCTAssertTrue(model.records.isEmpty); XCTAssertFalse(model.busy)
        await model.loadStatus(); XCTAssertEqual(model.status?.status, .notImported)
    }
}

private actor HistoryTestClient: ImportedHistoryClient {
    let example: ImportedHistoryExample
    private var failure: ImportedHistoryFailure?
    private var next: ImportedHistoryPage?
    private var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var pageCalls = 0
    init(example: ImportedHistoryExample) { self.example = example }
    func status() -> ImportedHistoryStatus { example.status }
    func failNext(_ value: ImportedHistoryFailure) { failure = value }
    func overrideNext(_ value: ImportedHistoryPage) { next = value }
    func holdNextPage() { hold = true }
    func waitUntilHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    func page(_ query: ImportedHistoryQuery) async throws -> ImportedHistoryPage {
        pageCalls += 1
        if hold { hold = false; await withCheckedContinuation { continuation = $0 } }
        if let failure { self.failure = nil; throw failure }
        if let next { self.next = nil; return next }
        return query.cursor == nil ? example.pages.presence : example.pages.presenceNext
    }
    func presence(snapshotID: String, record: ImportedPresenceRecord) -> ImportedHistoryDetail { example.detail }
}
