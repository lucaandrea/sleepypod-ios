import XCTest
@testable import Sleepypod

@MainActor final class BiometricDatasetTests: XCTestCase {
    func testCoreFixturesPreserveCadenceGapsAndDescriptivePartitions() throws {
        let fixture = try BiometricDatasetDemoFixture.load(side: .left)
        XCTAssertEqual(fixture.snapshots.count, 6)
        let inspection = try XCTUnwrap(fixture.capabilities.first { $0.session.id == 100 })
        XCTAssertEqual(inspection.processed.vitals.count, 6)
        XCTAssertEqual(inspection.processed.vitals.gapDurationMs, 6_840_000)
        XCTAssertEqual(inspection.processed.vitals.interpretation, "cadence_availability_not_measured_support")
        XCTAssertEqual(inspection.processed.legacyUnknownProvenanceCount, 6)
        XCTAssertFalse(try XCTUnwrap(fixture.capabilities.first { $0.session.id == 102 }).comparison)
        for snapshot in fixture.snapshots {
            XCTAssertTrue(BiometricDatasetRequest(selection: snapshot.selection).matches(snapshot.descriptor))
            XCTAssertEqual(snapshot.descriptor.manifest.splitProtocol.evidence, "descriptive_only")
            XCTAssertFalse(snapshot.descriptor.manifest.capabilities.signalReplay)
            XCTAssertTrue(snapshot.descriptor.manifest.supported)
        }
    }
    func testSelectionRequiresInspectedSideAndOneReferenceRevisionPerFamily() throws {
        let left = try BiometricDatasetDemoFixture.load(side: .left), right = try BiometricDatasetDemoFixture.load(side: .right)
        let draft = BiometricDatasetDraft(side: .left); draft.subjectId = " demo-sleeper "
        XCTAssertThrowsError(try draft.include(right.capabilities[0]))
        XCTAssertThrowsError(try draft.include(try XCTUnwrap(left.capabilities.first { !$0.comparison })))
        try draft.include(try XCTUnwrap(left.capabilities.first { $0.comparison }))
        let reference = try XCTUnwrap(left.references.items.first); try draft.include(reference)
        let correction = ReferenceDescriptor(id: UUID().uuidString.lowercased(), familyId: reference.familyId, revision: 2, supersedesImportId: reference.id, summary: reference.summary, createdAtMs: reference.createdAtMs + 1, deletedAtMs: nil, available: true, alreadyImported: nil)
        XCTAssertThrowsError(try draft.include(correction))
        XCTAssertThrowsError(try draft.include(try XCTUnwrap(right.references.items.first)))
        XCTAssertTrue(draft.valid); XCTAssertEqual(draft.selection.subjectId, "demo-sleeper")
        draft.subjectId = "different-sleeper"
        XCTAssertTrue(draft.selectedReferences.isEmpty); XCTAssertEqual(draft.selectedSessions.count, 1)
    }
    func testRequestBoundsAndExplicitlyOmittedControllerTimezone() throws {
        let fixture = try BiometricDatasetDemoFixture.load(side: .left)
        let request = BiometricDatasetRequest(selection: fixture.snapshots[0].selection, key: "exact-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["side", "subjectId", "sessionIds", "referenceImportIds", "idempotencyKey"])
        XCTAssertNil(body["timezone"])
        for selection in [
            BiometricDatasetSelection(side: .left, subjectId: "person", sessionIds: [1, 1], referenceImportIds: []),
            .init(side: .left, subjectId: "person", sessionIds: Array(1...61), referenceImportIds: []),
            .init(side: .left, subjectId: String(repeating: "😀", count: 101), sessionIds: [1], referenceImportIds: []),
            .init(side: .left, subjectId: "person", sessionIds: [1], referenceImportIds: ["../other"])
        ] { XCTAssertThrowsError(try selection.validated()) }
    }
    func testLostCreateResponseReopensWithoutWriteAndRetriesSameIdentity() async throws {
        let client = DatasetLifecycleClient(); await client.loseCreateResponse()
        let store = BiometricBacktestPendingStore(directory: nil)
        let first = BiometricDatasetWorkspace(side: .left, client: client, store: store)
        let selection = try BiometricDatasetDemoFixture.load(side: .left).snapshots[0].selection
        await first.create(selection)
        XCTAssertNotNil(first.pending); XCTAssertNil(first.receipt)
        let reopened = BiometricDatasetWorkspace(side: .left, client: client, store: store)
        let initial = await client.creationRequests(); XCTAssertEqual(initial.count, 1)
        await reopened.retry()
        let attempts = await client.creationRequests(); XCTAssertEqual(attempts.count, 2); XCTAssertEqual(attempts[0], attempts[1])
        XCTAssertNil(reopened.pending); XCTAssertNotNil(reopened.receipt); XCTAssertTrue(reopened.notice?.contains("does not run an evaluation") == true)
    }
    func testRetryReturnsReleasedDatasetWithoutRecreatingInputs() async throws {
        let client = DatasetLifecycleClient(); await client.loseCreateResponse()
        let model = BiometricDatasetWorkspace(side: .left, client: client, store: BiometricBacktestPendingStore(directory: nil))
        let selection = try BiometricDatasetDemoFixture.load(side: .left).snapshots[0].selection
        await model.create(selection); try await client.releaseCreatedDataset(); await model.retry()
        XCTAssertNil(model.pending); XCTAssertEqual(model.receipt?.available, false)
        XCTAssertTrue(model.notice?.contains("cannot run a new evaluation") == true)
    }
    func testUnknownReleaseReadbackDoesNotRepeatEffect() async throws {
        let client = DatasetLifecycleClient(), store = BiometricBacktestPendingStore(directory: nil)
        let model = BiometricDatasetWorkspace(side: .left, client: client, store: store)
        await model.create(try BiometricDatasetDemoFixture.load(side: .left).snapshots[0].selection)
        let saved = try XCTUnwrap(model.receipt); await client.loseReleaseResponse(); await model.release(saved)
        XCTAssertNotNil(model.pending); XCTAssertNil(model.receipt)
        await model.inspectRelease()
        XCTAssertNil(model.pending); XCTAssertEqual(model.receipt?.available, false)
        let releases = await client.releaseCount(); XCTAssertEqual(releases, 1)
        XCTAssertEqual(model.receipt?.contentHash, saved.contentHash)
        XCTAssertLessThan(try XCTUnwrap(model.receipt).byteLength, saved.byteLength)
    }
    func testAnotherWorkspaceDiscardPreventsStaleRetry() async throws {
        let client = DatasetLifecycleClient(); await client.loseCreateResponse()
        let store = BiometricBacktestPendingStore(directory: nil)
        let first = BiometricDatasetWorkspace(side: .left, client: client, store: store)
        await first.create(try BiometricDatasetDemoFixture.load(side: .left).snapshots[0].selection)
        let second = BiometricDatasetWorkspace(side: .left, client: client, store: store); second.discardPending()
        await first.retry()
        let requests = await client.creationRequests(); XCTAssertEqual(requests.count, 1)
        XCTAssertNil(first.receipt); XCTAssertTrue(first.error?.contains("removed or replaced") == true)
    }
    func testUnexpectedCreateReceiptKeepsExactPendingRequest() async throws {
        let client = DatasetLifecycleClient(); await client.returnWrongSide()
        let model = BiometricDatasetWorkspace(side: .left, client: client, store: .init(directory: nil))
        await model.create(try BiometricDatasetDemoFixture.load(side: .left).snapshots[0].selection)
        XCTAssertNil(model.receipt); XCTAssertNotNil(model.pending)
        XCTAssertTrue(model.error?.contains("does not match") == true)
    }
    func testProtectedStoreKeepsControllerAndSideIsolationAndCompetingIntent() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = BiometricBacktestPendingStore(directory: folder), second = BiometricBacktestPendingStore(directory: folder)
        let selection = try BiometricDatasetDemoFixture.load(side: .left).snapshots[0].selection
        let pending = BiometricBacktestPending.dataset(.init(selection: selection, key: "first"))
        try first.write(pending, scope: "https://pod-one.invalid", side: .left)
        XCTAssertEqual(try second.read(scope: "https://pod-one.invalid", side: .left), pending)
        XCTAssertNil(try second.read(scope: "https://pod-two.invalid", side: .left)); XCTAssertNil(try second.read(scope: "https://pod-one.invalid", side: .right))
        let other = BiometricBacktestPending.dataset(.init(selection: selection, key: "other"))
        XCTAssertThrowsError(try second.write(other, scope: "https://pod-one.invalid", side: .left))
        XCTAssertThrowsError(try second.remove(other, scope: "https://pod-one.invalid", side: .left))
        XCTAssertEqual(try first.read(scope: "https://pod-one.invalid", side: .left), pending)
    }
}

private actor DatasetLifecycleClient: BiometricDatasetsServing {
    nonisolated let scope = "test-dataset-controller"
    nonisolated var reportClient: any BiometricReportsServing { demo.reportClient }
    nonisolated var evaluationProfileClient: any BiometricProfilesServing { demo.evaluationProfileClient }
    private let demo = DemoBiometricDatasetsClient()
    private var createRequests: [BiometricDatasetRequest] = []
    private var releaseRequests = 0
    private var loseCreate = false
    private var loseRelease = false
    private var wrongSide = false
    private var created: BiometricDataset?
    func loseCreateResponse() { loseCreate = true }
    func loseReleaseResponse() { loseRelease = true }
    func returnWrongSide() { wrongSide = true }
    func creationRequests() -> [BiometricDatasetRequest] { createRequests }
    func releaseCount() -> Int { releaseRequests }
    func releaseCreatedDataset() async throws { if let created { _ = try await demo.release(id: created.id) } }
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
    func create(_ request: BiometricDatasetRequest) async throws -> BiometricDataset {
        createRequests.append(request)
        let result = try await demo.create(request); created = result
        if loseCreate { loseCreate = false; throw URLError(.timedOut) }
        if wrongSide { return .init(id: result.id, side: .right, subjectId: result.subjectId, contentHash: result.contentHash, manifest: result.manifest, byteLength: result.byteLength, createdAtMs: result.createdAtMs, releasedAtMs: nil, available: true) }
        return result
    }
    func replayAdmission() async throws -> ReplayAdmission { try await demo.replayAdmission() }
    func rawSources(startMs: Double, endMs: Double, cursor: String?) async throws -> InspectedRawPage { try await demo.rawSources(startMs: startMs, endMs: endMs, cursor: cursor) }
    func inspectRaw(afterName: String?) async throws -> RawInspectionResult { try await demo.inspectRaw(afterName: afterName) }
    func createWaveform(_ request: WaveformDatasetRequest) async throws -> WaveformDatasetResponse { try await demo.createWaveform(request) }
    func release(id: String) async throws -> BiometricDataset {
        releaseRequests += 1; let result = try await demo.release(id: id)
        if loseRelease { loseRelease = false; throw URLError(.timedOut) }; return result
    }
}
