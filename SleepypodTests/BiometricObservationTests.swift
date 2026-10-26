import XCTest
@testable import Sleepypod

@MainActor final class BiometricObservationTests: XCTestCase {
    private func input(side: Side = .left) -> BiometricObservationPreparation {
        let start = (Date.now.timeIntervalSince1970 * 1000 + 300000).rounded()
        return .init(templateId: "demo-plan-only", side: side, subjectId: "Synthetic sleeper", candidateRevisionId: nil, startMs: start, endMs: start + 300000)
    }
    func testLiteralCoreReportsMatchRunAndReference() throws {
        let example = try BiometricObservationExample.load()
        try example.run.validate(side: .left)
        try example.report.validate(run: example.run)
        try example.comparison.validate(run: example.run, reference: example.reference)
        XCTAssertNil(example.report.referenceSummary)
        XCTAssertEqual(example.report.reportHash, "2e782676e1dcc31a7a9f40981a8cfc65aa8f657d65a9202e9470457edbfd4a86")
        XCTAssertEqual(example.comparison.reportHash, "d79f60770602c73891a7b5b233d7bb8dac39b1aaeeeff3260be3adf306ca7996")
        XCTAssertTrue(example.report.metrics.contains { $0.candidate.usableCount < $0.current.usableCount })
        XCTAssertThrowsError(try example.comparison.validate(run: example.run))
        let wrongReference = ReferenceImportInput(side: .right, subjectId: example.reference.subjectId, source: example.reference.source, rows: example.reference.rows)
        XCTAssertThrowsError(try example.comparison.validate(run: example.run, reference: wrongReference))
        var value = try JSONValue.encoded(example.report)
        value = try value.replacing(at: "planHash", with: .string(String(repeating: "a", count: 64)))
        let wrong = try JSONDecoder().decode(BiometricObservationReport.self, from: JSONEncoder().encode(value))
        XCTAssertThrowsError(try wrong.validate(run: example.run))
    }
    func testUTCWindowAndCompleteReferenceEnvelopeBounds() throws {
        XCTAssertEqual(try BiometricObservationUTC.parse("2026-10-26T23:00:00.123Z"), 1793055600123)
        XCTAssertEqual(try BiometricObservationUTC.parse("2026-10-26T23:00:00Z"), 1793055600000)
        for text in ["2026-02-30T23:00:00Z", "2026-10-26T23:00:00", "2026-10-26T23:00:00.1234Z", "2026-10-26T23:00:00-07:00"] {
            XCTAssertThrowsError(try BiometricObservationUTC.parse(text))
        }
        let value = input(); try value.validate(maximumWindowMs: 600000)
        XCTAssertEqual(value.body["candidateRevisionId"], .null)
        XCTAssertThrowsError(try value.validate(maximumWindowMs: 1000))
        XCTAssertThrowsError(try value.validate(maximumWindowMs: 600000, now: .init(timeIntervalSince1970: value.endMs / 1000)))
        let example = try BiometricObservationExample.load()
        XCTAssertThrowsError(try BiometricObservationReference.parse(run: example.run, source: "Test", text: String(repeating: "x", count: 65537), format: .csv))
        let oversized = ReferenceImportInput(side: .left, subjectId: example.run.subjectId, source: "Test", rows: (0..<1500).map { index in
            .object(["recordKey": .string(String(repeating: "a", count: 100) + String(index)), "metric": .string("heartRate"), "value": .number(65), "unit": .string("bpm"), "timestamp": .number(1793055600000 + Double(index))])
        })
        XCTAssertThrowsError(try BiometricObservationReference(run: example.run, input: oversized).body())
    }
    func testPreparedPlanDoesNotSubmitAndDemoRunHasNoFabricatedObservations() async throws {
        let client = DemoBiometricObservationsClient(profiles: .init())
        let workspace = BiometricObservationsWorkspace(side: .left, client: client, pendingStore: .init(directory: nil))
        await workspace.loadTemplates(); await workspace.prepare(input())
        let prepared = try XCTUnwrap(workspace.prepared)
        let selected = input(side: .right)
        XCTAssertThrowsError(try prepared.validate(for: selected))
        let before = try await client.list(side: .left, afterId: nil); XCTAssertEqual(before.items.count, 1)
        await workspace.schedule()
        let run = try XCTUnwrap(workspace.savedRun)
        XCTAssertTrue(prepared.matches(run)); XCTAssertEqual(run.state, .pending); XCTAssertEqual(run.pointCount, 0)
        let report = try await client.report(id: run.id); try report.validate(run: run)
        XCTAssertTrue(report.metrics.isEmpty); XCTAssertNil(report.workerReceipt); XCTAssertEqual(report.observedSamples, 0)
        let stop = try await client.stop(id: run.id); XCTAssertEqual(stop.run.state, .stopped); XCTAssertFalse(stop.localAttemptSettled)
    }
    func testLostCreateReplyPersistsAndReopensWithoutAutomaticRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ObservationFaultClient(), workspace = BiometricObservationsWorkspace(side: .left, client: client, pendingStore: .init(directory: directory))
        await workspace.loadTemplates(); await workspace.prepare(input()); await client.loseNextCreate(); await workspace.schedule()
        guard case .create(let retained) = workspace.pending else { return XCTFail("Exact plan was not retained") }
        let reopened = BiometricObservationsWorkspace(side: .left, client: client, pendingStore: .init(directory: directory))
        await reopened.loadList()
        var calls = await client.creates; XCTAssertEqual(calls.count, 1)
        await reopened.retry()
        calls = await client.creates; XCTAssertEqual(calls, [retained, retained])
        XCTAssertNil(reopened.pending); XCTAssertTrue(retained.prepared.matches(try XCTUnwrap(reopened.savedRun)))
        let page = try await client.list(side: .left, afterId: nil); XCTAssertEqual(page.items.count, 2)
    }
    func testStopReadbackResolvesLostReplyWithoutSecondStopOrCleanupClaim() async throws {
        let client = ObservationFaultClient(), store = BiometricObservationPendingStore(directory: nil)
        let workspace = BiometricObservationsWorkspace(side: .left, client: client, pendingStore: store)
        await workspace.loadTemplates(); await workspace.prepare(input()); await workspace.schedule()
        let run = try XCTUnwrap(workspace.savedRun)
        await client.loseNextStop(); await workspace.stop(run)
        XCTAssertNotNil(workspace.pending)
        let reopened = BiometricObservationsWorkspace(side: .left, client: client, pendingStore: store)
        await reopened.retry()
        let stops = await client.stopCalls; XCTAssertEqual(stops, 1)
        XCTAssertEqual(reopened.savedRun?.state, .stopped); XCTAssertNil(reopened.pending)
        XCTAssertTrue(reopened.notice?.contains("cleanup was not confirmed") == true)
    }
    func testFailedReadsAndRemovedRetryNeverBecomeNewEffects() async throws {
        let client = ObservationFaultClient(), store = BiometricObservationPendingStore(directory: nil)
        let workspace = BiometricObservationsWorkspace(side: .left, client: client, pendingStore: store)
        await workspace.loadList(); let first = workspace.page?.items
        await client.failReads(); await workspace.loadList()
        XCTAssertEqual(workspace.page?.items, first); XCTAssertNotNil(workspace.listError)
        await client.restoreReads(); await workspace.loadTemplates(); await workspace.prepare(input())
        await client.loseNextCreate(); await workspace.schedule()
        let retained = try XCTUnwrap(workspace.pending)
        try store.remove(retained, scope: client.scope, side: .left)
        await workspace.retry()
        let calls = await client.creates; XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(workspace.mutationError?.contains("changed in another workspace") == true)
    }
    func testConfirmedStopSupersedesAnOlderInFlightRead() async throws {
        let client = ObservationFaultClient(), workspace = BiometricObservationsWorkspace(side: .left, client: client, pendingStore: .init(directory: nil))
        await workspace.loadTemplates(); await workspace.prepare(input()); await workspace.schedule()
        let run = try XCTUnwrap(workspace.savedRun), details = BiometricObservationDetailsWorkspace(run: try XCTUnwrap(workspace.savedRun), client: client)
        await client.holdGet()
        let read = Task { await details.refresh() }
        await client.waitForGet()
        XCTAssertTrue(details.reading)
        let stopped = try await client.stop(id: run.id); details.accept(stopped.run)
        await client.releaseGet(); await read.value
        XCTAssertEqual(details.run.state, .stopped)
    }
    func testLateComparisonCannotRestoreChangedInput() async throws {
        let client = ObservationFaultClient(), example = try BiometricObservationExample.load()
        let details = BiometricObservationDetailsWorkspace(run: example.run, client: client)
        await client.holdComparison()
        let comparison = Task { await details.compare(source: example.reference.source, text: JSONValue.array(example.reference.rows).formattedJSON, format: .json) }
        await client.waitForComparison()
        XCTAssertTrue(details.comparing); details.clearComparison(); await client.releaseComparison(); await comparison.value
        XCTAssertNil(details.comparison); XCTAssertFalse(details.comparing)
        await details.loadReport(); XCTAssertNotNil(details.report)
        await client.failReads(); await details.loadReport()
        XCTAssertNotNil(details.report); XCTAssertNotNil(details.reportError)
    }
}

private actor ObservationFaultClient: BiometricObservationsServing {
    nonisolated let scope = "observation-tests.invalid"
    nonisolated let profilesClient: any BiometricProfilesServing
    private let demo: DemoBiometricObservationsClient
    private var loseCreate = false, loseStop = false, readsFail = false, holdCompare = false
    private var comparisonContinuation: CheckedContinuation<Void, Never>?
    private var comparisonObserver: CheckedContinuation<Void, Never>?
    func waitForComparison() async { if !comparisonWaiting { await withCheckedContinuation { comparisonObserver = $0 } } }
    private(set) var comparisonWaiting = false
    private var heldGet = false
    private(set) var getWaiting = false
    private var getContinuation: CheckedContinuation<Void, Never>?
    private var getObserver: CheckedContinuation<Void, Never>?
    func waitForGet() async { if !getWaiting { await withCheckedContinuation { getObserver = $0 } } }
    func holdGet() { heldGet = true }
    func releaseGet() { heldGet = false; getContinuation?.resume(); getContinuation = nil }
    private(set) var creates: [BiometricObservationSubmission] = []
    private(set) var stopCalls = 0
    init() { let profiles = DemoBiometricProfilesClient(); profilesClient = profiles; demo = .init(profiles: profiles) }
    func loseNextCreate() { loseCreate = true }
    func loseNextStop() { loseStop = true }
    func failReads() { readsFail = true }
    func restoreReads() { readsFail = false }
    func holdComparison() { holdCompare = true }
    func releaseComparison() { holdCompare = false; comparisonContinuation?.resume(); comparisonContinuation = nil }
    func templates() async throws -> BiometricObservationTemplates { await demo.templates() }
    func prepare(_ input: BiometricObservationPreparation) async throws -> BiometricObservationPrepared { try await demo.prepare(input) }
    func create(_ input: BiometricObservationSubmission) async throws -> BiometricObservationRun {
        creates.append(input); let value = try await demo.create(input)
        if loseCreate { loseCreate = false; throw URLError(.networkConnectionLost) }; return value
    }
    func list(side: Side, afterId: String?) async throws -> BiometricObservationPage {
        if readsFail { throw URLError(.notConnectedToInternet) }; return try await demo.list(side: side, afterId: afterId)
    }
    func get(id: String) async throws -> BiometricObservationRun {
        if readsFail { throw URLError(.notConnectedToInternet) }
        let value = try await demo.get(id: id)
        if heldGet { getWaiting = true; getObserver?.resume(); getObserver = nil; await withCheckedContinuation { getContinuation = $0 } }
        return value
    }
    func stop(id: String) async throws -> BiometricObservationStop {
        stopCalls += 1; let value = try await demo.stop(id: id)
        if loseStop { loseStop = false; throw URLError(.networkConnectionLost) }; return value
    }
    func report(id: String) async throws -> BiometricObservationReport {
        if readsFail { throw URLError(.notConnectedToInternet) }; return try await demo.report(id: id)
    }
    func compare(_ input: BiometricObservationReference) async throws -> BiometricObservationReport {
        if holdCompare { comparisonWaiting = true; comparisonObserver?.resume(); comparisonObserver = nil; await withCheckedContinuation { comparisonContinuation = $0 } }
        return try await demo.compare(input)
    }
}
