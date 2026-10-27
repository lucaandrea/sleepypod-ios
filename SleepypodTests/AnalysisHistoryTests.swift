import XCTest
@testable import Sleepypod

@MainActor final class AnalysisHistoryTests: XCTestCase {
    func testLoadsAll650RecordsAcrossSidesPagesAndDateWindows() async throws {
        let client = try AnalysisArchiveClient(), progress = AnalysisHistoryProgress()
        let records = try await AnalysisHistoryReader.archive(client) { progress.counts.append($0); progress.total = $1 }
        XCTAssertEqual(records.count, 650)
        XCTAssertEqual(Set(records.map(\.id)).count, 650)
        XCTAssertEqual(records.filter { $0.side == .left }.count, 325)
        XCTAssertTrue(records.allSatisfy(\.archived))
        XCTAssertEqual(records.map(\.start), records.map(\.start).sorted(by: >))
        XCTAssertEqual(progress.total, 650); XCTAssertEqual(progress.counts.last, 650)
        let queries = await client.queries
        XCTAssertGreaterThan(queries.count, 4)
        XCTAssertTrue(queries.contains { $0.cursor != nil })
        XCTAssertTrue(queries.allSatisfy { $0.end.timeIntervalSince($0.start) <= 90 * 86400 })
    }

    func testIncompleteOrChangedArchivesCannotReportCompleteHistory() async throws {
        for failure in [AnalysisArchiveClient.Failure.missingRecord, .changed, .repeatedCursor] {
            let client = try AnalysisArchiveClient(failure: failure)
            do { _ = try await AnalysisHistoryReader.archive(client) { _, _ in }; XCTFail("Expected \(failure) to fail") }
            catch {
                switch failure {
                case .missingRecord: XCTAssertTrue(error.localizedDescription.contains("649 of 650"))
                case .changed: XCTAssertTrue(error.localizedDescription.contains("changed"))
                case .repeatedCursor: XCTAssertTrue(error.localizedDescription.contains("page"))
                }
            }
        }
    }

    func testMissingArchiveKeepsCurrentRecordsAndShowsFailure() async throws {
        let probe = AnalysisCurrentProbe(), model = AnalysisHistoryWorkspace()
        await model.load(api: AnalysisCurrentClient(probe), archive: try AnalysisArchiveClient(failure: .changed))
        XCTAssertTrue(model.loaded); XCTAssertFalse(model.loading)
        XCTAssertEqual(model.records.count, 1); XCTAssertFalse(model.records[0].archived)
        XCTAssertEqual(model.errors.count, 1)
        XCTAssertEqual(probe.start, Date(timeIntervalSince1970: 0))
        XCTAssertNil(probe.side)
    }

    func testCancelledLoadCannotPublishIntoANewerAnalysis() async {
        let probe = AnalysisCurrentProbe(), model = AnalysisHistoryWorkspace()
        probe.hold = true
        let pending = Task { await model.load(api: AnalysisCurrentClient(probe), archive: nil) }
        await probe.waitHeld(); model.cancel(); probe.release(); await pending.value
        XCTAssertFalse(model.loading); XCTAssertFalse(model.loaded)
        XCTAssertTrue(model.records.isEmpty); XCTAssertTrue(model.currentRecords.isEmpty)
    }

    func testDemoArchiveReadsAllFixturePresenceRecords() async throws {
        let records = try await AnalysisHistoryReader.archive(DemoImportedHistoryClient(scenario: "loaded")) { _, _ in }
        XCTAssertEqual(records.count, 2)
    }

    func testAll1100VitalReadingsLoadWithoutInventingBedSessions() async throws {
        let data = try await AnalysisHistoryReader.all(AnalysisArchiveClient(presenceEnabled: false, withVitals: true)) { _, _, _ in }
        XCTAssertTrue(data.presence.isEmpty)
        XCTAssertEqual(data.vitals.count, 1100)
        XCTAssertEqual(data.vitals.filter { $0.side == .right }.count, 550)
        XCTAssertEqual(data.movementCount, 0)
    }

    func testDemoOverviewLoadsEveryArchivedRecordType() async throws {
        let source = try ImportedHistoryExample.load()
        let data = try await AnalysisHistoryReader.all(DemoImportedHistoryClient(scenario: "loaded")) { _, _, _ in }
        let snapshot = try XCTUnwrap(source.status.snapshot)
        let expected = Side.allCases.reduce(0) { $0 + snapshot.bounds(side: $1, kind: .vitals).readableRecords }
        XCTAssertEqual(data.vitals.count, expected); XCTAssertEqual(data.presence.count, 2)
    }
}

@MainActor private final class AnalysisHistoryProgress {
    var counts: [Int] = []
    var total = 0
}

/// Synthetic multi-month history exercises real pagination and overlapping presence windows.
private actor AnalysisArchiveClient: ImportedHistoryClient {
    enum Failure { case missingRecord, changed, repeatedCursor }
    let source: ImportedHistoryStatus
    let records: [ImportedPresenceRecord]
    let vitalRecords: [ImportedVitalsRecord]
    let failure: Failure?
    private(set) var queries: [ImportedHistoryQuery] = []
    init(failure: Failure? = nil, presenceEnabled: Bool = true, withVitals: Bool = false) throws {
        self.failure = failure
        let base = 1_700_000_000.0
        records = presenceEnabled ? Side.allCases.flatMap { side in (0..<325).map { index in
            let start = base + Double(index) * 43200
            return ImportedPresenceRecord(id: index + 1, side: side, enteredBedAt: start, leftBedAt: start + 28800,
                                          reportedDurationSeconds: 28800, exits: 0)
        } } : []
        vitalRecords = withVitals ? Side.allCases.flatMap { side in (0..<550).map { index in
            ImportedVitalsRecord(id: index + 1, side: side, timestamp: base + Double(index) * 43200,
                                 heartRateBpm: Double(60 + index % 10), hrvEstimateMs: 35, breathingRatePerMinute: 14)
        } } : []
        var status = try ImportedHistoryExample.load().status
        let empty = ImportedHistoryBounds(records: 0, readableRecords: 0, firstAt: nil, lastAt: nil)
        let bounds = presenceEnabled ? ImportedHistoryBounds(records: 325, readableRecords: 325, firstAt: base, lastAt: base + 324 * 43200 + 28800) : empty
        status.snapshot?.sides.left.presence = bounds; status.snapshot?.sides.right.presence = bounds
        let vitals = withVitals ? ImportedHistoryBounds(records: 550, readableRecords: 550, firstAt: base, lastAt: base + 549 * 43200) : empty
        status.snapshot?.sides.left.vitals = vitals; status.snapshot?.sides.right.vitals = vitals
        status.snapshot?.sides.left.movement = empty; status.snapshot?.sides.right.movement = empty
        source = status
    }
    func status() -> ImportedHistoryStatus { source }
    func page(_ query: ImportedHistoryQuery) throws -> ImportedHistoryPage {
        queries.append(query)
        if failure == .changed { throw ImportedHistoryFailure.changed }
        let candidates = query.kind == .vitals ? vitalRecords.map(ImportedHistoryRecord.vitals) : records.map(ImportedHistoryRecord.presence)
        let matching = candidates.filter { record in
            guard record.side == query.side, !(failure == .missingRecord && record.side == .right && record.sourceID == 1) else { return false }
            if case .presence(let presence) = record {
                return presence.enteredBedAt < query.end.timeIntervalSince1970 && presence.leftBedAt > query.start.timeIntervalSince1970
            }
            return record.timestamp >= query.start.timeIntervalSince1970 && record.timestamp < query.end.timeIntervalSince1970
        }.sorted { $0.timestamp > $1.timestamp }
        let offset = Int(query.cursor ?? "0") ?? 0
        let page = Array(matching.dropFirst(offset).prefix(query.limit))
        let next = offset + page.count < matching.count ? String(offset + page.count) : nil
        return .init(apiVersion: 1, snapshotId: query.snapshotID, side: query.side, kind: query.kind, records: page,
                     nextCursor: failure == .repeatedCursor ? "100" : next, semantics: source.semantics)
    }
    func presence(snapshotID: String, record: ImportedPresenceRecord) throws -> ImportedHistoryDetail {
        throw ImportedHistoryFailure.unavailable("Detail is not part of the overview")
    }
}

@MainActor private final class AnalysisCurrentProbe {
    var hold = false
    var start: Date?
    var side: Side?
    private var continuation: CheckedContinuation<Void, Never>?
    func read(side: Side?, start: Date?) async -> [SleepRecord] {
        self.side = side; self.start = start
        if hold { await withCheckedContinuation { continuation = $0 } }
        return [.init(id: 1, side: "left", enteredBed: Date(timeIntervalSince1970: 1_700_000_000),
                      leftBed: Date(timeIntervalSince1970: 1_700_028_800))]
    }
    func waitHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
private final class AnalysisCurrentClient: MockAPIClient, @unchecked Sendable {
    let probe: AnalysisCurrentProbe
    init(_ probe: AnalysisCurrentProbe) { self.probe = probe; super.init() }
    override func getSleepRecords(side: Side?, start: Date?, end: Date?) async throws -> [SleepRecord] {
        await probe.read(side: side, start: start)
    }
}
