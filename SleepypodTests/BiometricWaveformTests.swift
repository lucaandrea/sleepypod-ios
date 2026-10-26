import XCTest
@testable import Sleepypod

@MainActor final class BiometricWaveformTests: XCTestCase {
    func testCorePreparedExamplesPreserveEveryNightParentAndInspectionIdentity() throws {
        let fixtures = try BiometricWaveformDemoFixture.load()
        XCTAssertEqual(fixtures.count, 12)
        for fixture in fixtures {
            XCTAssertTrue(fixture.request.matches(fixture.descriptor, side: fixture.descriptor.side))
            XCTAssertTrue(fixture.descriptor.manifest.capabilities.signalReplay)
            XCTAssertEqual(fixture.descriptor.manifest.splitProtocol.evidence, "descriptive_only")
            XCTAssertTrue(fixture.pages.flatMap(\.page.items).allSatisfy(\.selectable))
            XCTAssertTrue(fixture.pages.flatMap(\.page.items).allSatisfy { !$0.inspection.retained })
        }
    }
    func testEveryFrozenNightRequiresAnInspectedOverlappingSelection() throws {
        let fixture = try example(twoNights: true)
        let parent = try self.parent(for: fixture), draft = WaveformDatasetDraft(parent: parent)
        let first = parent.manifest.splitProtocol.assignments[0], second = parent.manifest.splitProtocol.assignments[1]
        let source = try XCTUnwrap(fixture.pages.first { $0.cohortId == first.cohortId }?.page.items.first)
        XCTAssertThrowsError(try draft.toggle(source, cohort: second))
        try draft.toggle(source, cohort: first)
        XCTAssertFalse(draft.complete); XCTAssertThrowsError(try draft.request())
        let next = try XCTUnwrap(fixture.pages.first { $0.cohortId == second.cohortId }?.page.items.first)
        try draft.toggle(next, cohort: second); XCTAssertTrue(draft.complete)
        XCTAssertEqual(try draft.request(key: "exact-selection").cohorts.count, 2)
        draft.clear(first.cohortId); XCTAssertFalse(draft.complete)
    }
    func testWaveformPublicationKeepsTheOriginalProcessedReceipt() async throws {
        let client = DemoBiometricDatasetsClient()
        let model = BiometricDatasetWorkspace(side: .left, client: client, store: .init(directory: nil))
        let snapshot = try BiometricDatasetDemoFixture.load(side: .left).snapshots[0]
        await model.create(snapshot.selection)
        let original = try XCTUnwrap(model.receipt)
        let fixture = try XCTUnwrap(BiometricWaveformDemoFixture.load().first { $0.parentId == original.id })
        await model.retainWaveforms(fixture.request, side: .left)
        XCTAssertEqual(model.savedDataset?.id, original.id)
        XCTAssertEqual(model.receipt?.id, fixture.descriptor.id)
        XCTAssertEqual(model.savedWaveformRequest, fixture.request)
        XCTAssertEqual(model.savedSelection, snapshot.selection)
    }
    func testScanResponsesMustAdvanceAndDeferredScanPreservesCursor() throws {
        let source = try XCTUnwrap(BiometricWaveformDemoFixture.sources().first)
        let name = source.inspection.sourceName
        _ = try RawInspectionResult(status: .inspected, nextCursor: name, source: source).checked(after: nil)
        XCTAssertThrowsError(try RawInspectionResult(status: .inspected, nextCursor: name, source: source).checked(after: name))
        XCTAssertThrowsError(try RawInspectionResult(status: .inspected, nextCursor: "other.RAW.gz", source: source).checked(after: nil))
        XCTAssertThrowsError(try RawInspectionResult(status: .deferred, nextCursor: nil, source: nil).checked(after: name))
        _ = try RawInspectionResult(status: .deferred, nextCursor: name, source: nil).checked(after: name)
        XCTAssertThrowsError(try RawInspectionResult(status: .complete, nextCursor: name, source: nil).checked(after: nil))
        XCTAssertFalse(WaveformInput.validSourceName("../capture.RAW.gz"))
        XCTAssertFalse(WaveformInput.validSourceName("capture.RAW.gz\n"))
    }
    func testCorruptInventoryCannotBecomeSelectable() throws {
        let source = try XCTUnwrap(BiometricWaveformDemoFixture.sources().first)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        var inspection = try XCTUnwrap(json["inspection"] as? [String: Any])
        var inventory = try XCTUnwrap(inspection["inventory"] as? [String: Any])
        inventory["usable_dual_frames"] = 100
        inspection["inventory"] = inventory; json["inspection"] = inspection
        let bad = try JSONDecoder().decode(InspectedRawSource.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(bad.validIdentity); XCTAssertFalse(bad.selectable)
    }
    func testDeferredRetainReopensWithoutWriteAndRetriesExactRequest() async throws {
        let fixture = try example(), client = WaveformTestClient()
        await client.setOutcome(.deferred)
        let store = BiometricBacktestPendingStore(directory: nil)
        let model = BiometricDatasetWorkspace(side: .left, client: client, store: store)
        await model.retainWaveforms(fixture.request, side: .left)
        XCTAssertNotNil(model.pending); XCTAssertNil(model.receipt)
        let reopened = BiometricDatasetWorkspace(side: .left, client: client, store: store)
        let initial = await client.requests(); XCTAssertEqual(initial.count, 1)
        await reopened.retry()
        let attempts = await client.requests(); XCTAssertEqual(attempts, [fixture.request, fixture.request])
        XCTAssertNil(reopened.pending); XCTAssertEqual(reopened.receipt?.contentHash, fixture.descriptor.contentHash)
    }
    func testLostPublicationThenReleasedRetryDoesNotRecreateInputs() async throws {
        let fixture = try example(), client = WaveformTestClient()
        await client.setOutcome(.lost)
        let model = BiometricDatasetWorkspace(side: .left, client: client, store: .init(directory: nil))
        await model.retainWaveforms(fixture.request, side: .left)
        XCTAssertNotNil(model.pending); XCTAssertNil(model.receipt)
        try await client.releasePublished(); await model.retry()
        XCTAssertNil(model.pending); XCTAssertEqual(model.receipt?.available, false)
        XCTAssertTrue(model.notice?.contains("cannot run a new evaluation") == true)
    }
    func testWrongPublicationAndCompetingDiscardKeepRecoveryHonest() async throws {
        let fixture = try example(), client = WaveformTestClient()
        await client.setOutcome(.wrongParent)
        let store = BiometricBacktestPendingStore(directory: nil)
        let first = BiometricDatasetWorkspace(side: .left, client: client, store: store)
        await first.retainWaveforms(fixture.request, side: .left)
        XCTAssertNil(first.receipt); XCTAssertNotNil(first.pending)
        let other = BiometricDatasetWorkspace(side: .left, client: client, store: store); other.discardPending()
        await first.retry()
        let requests = await client.requests(); XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(first.error?.contains("removed or replaced") == true)
    }
    func testAdmissionMustBeFreshAndDeferredInspectionPreservesSelection() async throws {
        let fixture = try example(), client = WaveformTestClient(), parent = try self.parent(for: fixture)
        let workspace = WaveformSelectionWorkspace(parent: parent, client: client)
        let cohort = try XCTUnwrap(parent.manifest.splitProtocol.assignments.first)
        XCTAssertFalse(workspace.canInspect()); await workspace.refreshAdmission(); XCTAssertTrue(workspace.canInspect())
        XCTAssertFalse(workspace.canInspect(at: Date.now.addingTimeInterval(16)))
        let source = try XCTUnwrap(fixture.pages.first?.page.items.first)
        try workspace.draft.toggle(source, cohort: cohort)
        await client.deferScan(); await workspace.inspectNext(cohort: cohort)
        XCTAssertNil(workspace.scanCursor); XCTAssertTrue(workspace.draft.complete)
        XCTAssertTrue(workspace.scanNotice?.contains("deferred") == true)
        await client.failAdmission(); await workspace.refreshAdmission(); XCTAssertFalse(workspace.canInspect())
    }
    func testNewNightResponseWinsOverAnOlderRead() async throws {
        let fixture = try example(twoNights: true), client = WaveformTestClient(), parent = try self.parent(for: fixture)
        let workspace = WaveformSelectionWorkspace(parent: parent, client: client)
        await client.holdNextSourceRead()
        let first = Task { await workspace.loadSources(cohort: parent.manifest.splitProtocol.assignments[0]) }
        while !(await client.hasHeldSourceRead()) { await Task.yield() }
        await workspace.loadSources(cohort: parent.manifest.splitProtocol.assignments[1])
        let expected = workspace.sources?.items.map(\.id)
        await client.resumeSourceRead(); await first.value
        XCTAssertEqual(workspace.sourceCohortId, parent.manifest.splitProtocol.assignments[1].cohortId)
        XCTAssertEqual(workspace.sources?.items.map(\.id), expected)
        XCTAssertFalse(workspace.loadingSources)
    }
    private func example(twoNights: Bool = false) throws -> BiometricWaveformDemoFixture {
        try XCTUnwrap(BiometricWaveformDemoFixture.load().first { $0.descriptor.side == .left && $0.pages.count == (twoNights ? 2 : 1) })
    }
    private func parent(for fixture: BiometricWaveformDemoFixture) throws -> BiometricDataset {
        try XCTUnwrap(BiometricDatasetDemoFixture.load(side: fixture.descriptor.side).snapshots.first { $0.descriptor.id == fixture.parentId }?.descriptor)
    }
}

private actor WaveformTestClient: BiometricDatasetsServing {
    enum Outcome { case published, deferred, lost, wrongParent }
    nonisolated let scope = "test-waveform-controller"
    nonisolated var reportClient: any BiometricReportsServing { demo.reportClient }
    nonisolated var evaluationProfileClient: any BiometricProfilesServing { demo.evaluationProfileClient }
    private var outcome = Outcome.published
    private var sent: [WaveformDatasetRequest] = []
    private var published: BiometricDataset?
    private var admissionFails = false
    private var scanDeferred = false
    private var holdSource = false
    private var held: CheckedContinuation<Void, Never>?
    private let demo = DemoBiometricDatasetsClient()
    func setOutcome(_ value: Outcome) { outcome = value }
    func requests() -> [WaveformDatasetRequest] { sent }
    func deferScan() { scanDeferred = true }
    func failAdmission() { admissionFails = true }
    func holdNextSourceRead() { holdSource = true }
    func hasHeldSourceRead() -> Bool { held != nil }
    func resumeSourceRead() { held?.resume(); held = nil }
    func releasePublished() throws {
        guard let current = published else { throw URLError(.badServerResponse) }
        published = .init(id: current.id, side: current.side, subjectId: current.subjectId, contentHash: current.contentHash, manifest: current.manifest, byteLength: 0, createdAtMs: current.createdAtMs, releasedAtMs: current.createdAtMs + 1, available: false)
    }
    func replayAdmission() async throws -> ReplayAdmission {
        if admissionFails { throw URLError(.notConnectedToInternet) }
        return .init(configured: true, qualificationId: "synthetic", admitted: true, reasons: [])
    }
    func rawSources(startMs: Double, endMs: Double, cursor: String?) async throws -> InspectedRawPage {
        if holdSource { holdSource = false; await withCheckedContinuation { held = $0 } }
        return try await demo.rawSources(startMs: startMs, endMs: endMs, cursor: cursor)
    }
    func inspectRaw(afterName: String?) async throws -> RawInspectionResult {
        scanDeferred ? .init(status: .deferred, nextCursor: afterName, source: nil) : try await demo.inspectRaw(afterName: afterName)
    }
    func createWaveform(_ request: WaveformDatasetRequest) async throws -> WaveformDatasetResponse {
        sent.append(request)
        if outcome == .deferred { outcome = .published; return .init(status: .deferred, dataset: nil) }
        if outcome == .wrongParent { return .init(status: .published, dataset: try BiometricDatasetDemoFixture.load(side: .left).snapshots[0].descriptor) }
        if published == nil { published = try BiometricWaveformDemoFixture.load().first { $0.parentId == request.parentDatasetId }?.descriptor }
        if outcome == .lost { outcome = .published; throw URLError(.timedOut) }
        return .init(status: .published, dataset: published)
    }
    func evaluationOverview(side: Side) async throws -> BiometricProfileOverview { try await demo.evaluationOverview(side: side) }
    func evaluationProfiles(side: Side, cursor: BiometricProfilePage.Cursor?) async throws -> BiometricProfilePage { try await demo.evaluationProfiles(side: side, cursor: cursor) }
    func evaluationProfile(id: String) async throws -> BiometricProfileRevision { try await demo.evaluationProfile(id: id) }
    func jobs(side: Side, cursor: BiometricBacktestPage.Cursor?) async throws -> BiometricBacktestPage { try await demo.jobs(side: side, cursor: cursor) }
    func job(id: String) async throws -> BiometricBacktestJob { try await demo.job(id: id) }
    func submit(_ request: BiometricBacktestSubmission) async throws -> BiometricBacktestJob { try await demo.submit(request) }
    func cancelJob(id: String) async throws -> BiometricBacktestJob { try await demo.cancelJob(id: id) }
    func experiments(side: Side, cursor: BiometricExperimentPage.Cursor?) async throws -> BiometricExperimentPage { try await demo.experiments(side: side, cursor: cursor) }
    func experiment(id: String) async throws -> BiometricExperiment { try await demo.experiment(id: id) }
    func create(_ request: BiometricExperimentRequest) async throws -> BiometricExperiment { try await demo.create(request) }
    func sessions(side: Side, cursor: ReplaySessionPage.Cursor?) async throws -> ReplaySessionPage { try await demo.sessions(side: side, cursor: cursor) }
    func capabilities(side: Side, id: Int) async throws -> ReplaySessionCapabilities { try await demo.capabilities(side: side, id: id) }
    func references(side: Side, cursor: ReferenceLibraryPage.Cursor?) async throws -> ReferenceLibraryPage { try await demo.references(side: side, cursor: cursor) }
    func datasets(side: Side, cursor: BiometricDatasetPage.Cursor?) async throws -> BiometricDatasetPage { try await demo.datasets(side: side, cursor: cursor) }
    func dataset(id: String) async throws -> BiometricDataset { try await demo.dataset(id: id) }
    func create(_ request: BiometricDatasetRequest) async throws -> BiometricDataset { try await demo.create(request) }
    func release(id: String) async throws -> BiometricDataset { try await demo.release(id: id) }
}
