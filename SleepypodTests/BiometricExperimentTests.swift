import XCTest
@testable import Sleepypod

@MainActor final class BiometricExperimentTests: XCTestCase {
    struct Fixtures: Decodable {
        struct ProtocolVector: Decodable { let `protocol`: BiometricExperimentProtocol; let canonical: String; let hash: String }
        struct CanonicalVector: Decodable { let value: JSONValue; let canonical: String; let hash: String }
        let protocols: [ProtocolVector]
        let canonicalVectors: [CanonicalVector]
    }
    func testCoreProtocolFixturesAndExactBinary64HashEncoding() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "experiment-protocols", withExtension: "json"))
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixtures.protocols.count, 12)
        for item in fixtures.protocols {
            XCTAssertEqual(try BiometricDemoCanonicalJSON.canonical(.encoded(item.protocol)), item.canonical)
            XCTAssertEqual(try BiometricDemoCanonicalJSON.hash(item.protocol), item.hash)
            XCTAssertEqual(try JSONDecoder().decode(BiometricExperimentProtocol.self, from: JSONEncoder().encode(item.protocol)), item.protocol)
        }
        for item in fixtures.canonicalVectors {
            XCTAssertEqual(try BiometricDemoCanonicalJSON.canonical(item.value), item.canonical)
            XCTAssertEqual(try BiometricDemoCanonicalJSON.hash(item.value), item.hash)
        }
        XCTAssertNotEqual(fixtures.protocols[9].hash, fixtures.protocols[10].hash, "Single-policy and array representations retain different frozen identities")
        XCTAssertThrowsError(try BiometricDemoCanonicalJSON.canonical(.number(.infinity)))
    }
    func testEditorRequiresExplicitStageQualityAndCompatibleInputKind() throws {
        let processed = try parent(), draft = BiometricExperimentDraft(dataset: processed)
        XCTAssertTrue(draft.valid); XCTAssertEqual(draft.allowedModes, [.comparison, .stages])
        draft.mode = .stages
        for value in ["", " ", "NaN", "inf", "-0.1", "1.1"] { draft.quality = value; XCTAssertFalse(draft.valid) }
        draft.quality = "0.6"; XCTAssertTrue(draft.valid)
        draft.mode = .waveform; XCTAssertFalse(draft.valid)
        let waveform = try XCTUnwrap(BiometricWaveformDemoFixture.load().first { $0.parentId == processed.id })
        let rawDraft = BiometricExperimentDraft(dataset: waveform.descriptor)
        XCTAssertEqual(rawDraft.allowedModes, [.waveform]); XCTAssertTrue(rawDraft.valid)
        rawDraft.waveformStages = true; XCTAssertFalse(rawDraft.valid)
        rawDraft.quality = "0"; XCTAssertTrue(rawDraft.valid)
        rawDraft.mode = .comparison; XCTAssertFalse(rawDraft.valid)
    }
    func testMatchingAndUncertaintyBoundsDoNotConvertBlankToZero() throws {
        let draft = BiometricExperimentDraft(dataset: try parent()); draft.mode = .stages; draft.quality = "0.6"
        for value in ["", "-1", "300001", "1.5", "1e100"] { draft.tolerance = value; XCTAssertFalse(draft.valid) }
        draft.tolerance = "300000"; draft.offset = "-3600000"; XCTAssertTrue(draft.valid)
        draft.offset = "3600001"; XCTAssertFalse(draft.valid); draft.offset = "0"
        draft.estimateUncertainty = true; XCTAssertFalse(draft.valid)
        draft.seed = String(repeating: "😀", count: 32); XCTAssertTrue(draft.valid)
        draft.seed += "x"; XCTAssertFalse(draft.valid); draft.seed = "reproducible"
        draft.resamples = "199"; XCTAssertFalse(draft.valid); draft.resamples = "5000"
        draft.minimumNights = "61"; XCTAssertFalse(draft.valid); draft.minimumNights = "3"
        XCTAssertTrue(draft.valid)
        draft.mode = .comparison
        let request = try draft.request(key: "fixed")
        XCTAssertNil(request.protocol.nightUncertainty); XCTAssertEqual(request.protocol.assumedStageCalibrationQuality, 0)
        XCTAssertNil(request.protocol.waveformStages)
    }
    func testLostCreationReopensWithoutWritingAndRetriesExactProtocolAfterRelease() async throws {
        let client = ExperimentTestClient(), store = BiometricBacktestPendingStore(directory: nil)
        let dataset = try await retainedParent(client)
        let request = try BiometricExperimentDraft(dataset: dataset).request(key: "lost-reply")
        await client.loseNextCreate()
        let first = BiometricDatasetWorkspace(side: .left, client: client, store: store)
        await first.createExperiment(request, parent: dataset)
        XCTAssertNotNil(first.pending); XCTAssertNil(first.savedExperiment)
        _ = try await client.release(id: dataset.id)
        let reopened = BiometricDatasetWorkspace(side: .left, client: client, store: store)
        let attemptsBefore = await client.attempts(); XCTAssertEqual(attemptsBefore, [request])
        await reopened.retry()
        let attemptsAfter = await client.attempts(); XCTAssertEqual(attemptsAfter, [request, request])
        XCTAssertNil(reopened.pending); XCTAssertNotNil(reopened.savedExperiment)
        XCTAssertTrue(reopened.notice?.contains("No evaluation has run") == true)
        let inputs = try await client.dataset(id: dataset.id); XCTAssertFalse(inputs.available)
    }
    func testNewCreationRechecksFrozenInputBeforeRetainingAnyRequest() async throws {
        let client = ExperimentTestClient(), store = BiometricBacktestPendingStore(directory: nil)
        let dataset = try await retainedParent(client), request = try BiometricExperimentDraft(dataset: dataset).request()
        _ = try await client.release(id: dataset.id)
        let model = BiometricDatasetWorkspace(side: .left, client: client, store: store)
        await model.createExperiment(request, parent: dataset)
        let attempts = await client.attempts(); XCTAssertTrue(attempts.isEmpty)
        XCTAssertNil(model.pending); XCTAssertNotNil(model.error)
    }
    func testMismatchedReceiptKeepsPendingAndBlocksOtherInputChanges() async throws {
        let client = ExperimentTestClient(), store = BiometricBacktestPendingStore(directory: nil)
        let dataset = try await retainedParent(client), request = try BiometricExperimentDraft(dataset: dataset).request()
        await client.mismatchNextCreate()
        let model = BiometricDatasetWorkspace(side: .left, client: client, store: store)
        await model.createExperiment(request, parent: dataset)
        XCTAssertNotNil(model.pending); XCTAssertNil(model.savedExperiment); XCTAssertFalse(model.canMutate)
        await model.release(dataset)
        let retained = try await client.dataset(id: dataset.id); XCTAssertTrue(retained.available)
        let reopened = BiometricDatasetWorkspace(side: .left, client: client, store: store)
        reopened.discardPending(); await model.retry()
        let attempts = await client.attempts(); XCTAssertEqual(attempts.count, 1)
        XCTAssertTrue(model.error?.contains("removed or replaced") == true)
    }
    func testChangedProtocolCannotReuseKeyAndSharedClientRetainsLibrary() async throws {
        let client = ExperimentTestClient(), dataset = try await retainedParent(client)
        let draft = BiometricExperimentDraft(dataset: dataset), first = try draft.request(key: "one")
        let result = try await client.create(first)
        draft.offset = "1000"
        do { _ = try await client.create(draft.request(key: "one")); XCTFail("Changed key must conflict") } catch {}
        let library = BiometricExperimentLibrary(side: .left, client: client); await library.load()
        XCTAssertEqual(library.page?.items.map(\.id), [result.id]); XCTAssertNil(library.error)
        let otherSide = BiometricExperimentLibrary(side: .right, client: client); await otherSide.load()
        XCTAssertEqual(otherSide.page?.items.count, 0)
    }
    func testLateAndInvalidLibraryPagesCannotReplaceCurrentResults() async throws {
        let client = ExperimentTestClient(), dataset = try await retainedParent(client)
        let saved = try await client.create(BiometricExperimentDraft(dataset: dataset).request())
        let library = BiometricExperimentLibrary(side: .left, client: client)
        await client.holdNextPage()
        let old = Task { await library.load(.init(createdAtMs: saved.createdAtMs, id: saved.id)) }
        while !(await client.hasHeldPage()) { await Task.yield() }
        await library.load(); await client.resumePage(); await old.value
        XCTAssertNil(library.cursor); XCTAssertEqual(library.page?.items.map(\.id), [saved.id])
        await client.duplicateNextPage(); await library.load()
        XCTAssertNotNil(library.error); XCTAssertEqual(library.page?.items.map(\.id), [saved.id])
    }
    func testExperimentRequestPersistsWithReviewedParentHashAndSideIsolation() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let dataset = try parent(), request = try BiometricExperimentDraft(dataset: dataset).request(key: "durable")
        let pending = BiometricBacktestPending.experiment(parent: .init(id: dataset.id, contentHash: dataset.contentHash, side: .left), request: request)
        let store = BiometricBacktestPendingStore(directory: folder)
        try store.write(pending, scope: "controller-one", side: .left)
        let reopened = BiometricBacktestPendingStore(directory: folder)
        XCTAssertEqual(try reopened.read(scope: "controller-one", side: .left), pending)
        XCTAssertNil(try reopened.read(scope: "controller-one", side: .right)); XCTAssertNil(try reopened.read(scope: "controller-two", side: .left))
    }
    private func parent() throws -> BiometricDataset { try BiometricDatasetDemoFixture.load(side: .left).snapshots[0].descriptor }
    private func retainedParent(_ client: ExperimentTestClient) async throws -> BiometricDataset {
        try await client.create(.init(selection: BiometricDatasetDemoFixture.load(side: .left).snapshots[0].selection))
    }
}

private actor ExperimentTestClient: BiometricDatasetsServing {
    nonisolated let scope = "test-experiment-controller"
    nonisolated var reportClient: any BiometricReportsServing { demo.reportClient }
    nonisolated var evaluationProfileClient: any BiometricProfilesServing { demo.evaluationProfileClient }
    private let demo = DemoBiometricDatasetsClient()
    private var sent: [BiometricExperimentRequest] = []
    private var lose = false, mismatch = false, hold = false, duplicate = false
    private var held: CheckedContinuation<Void, Never>?
    func loseNextCreate() { lose = true }
    func mismatchNextCreate() { mismatch = true }
    func attempts() -> [BiometricExperimentRequest] { sent }
    func holdNextPage() { hold = true }
    func hasHeldPage() -> Bool { held != nil }
    func resumePage() { held?.resume(); held = nil }
    func duplicateNextPage() { duplicate = true }
    func evaluationOverview(side: Side) async throws -> BiometricProfileOverview { try await demo.evaluationOverview(side: side) }
    func evaluationProfiles(side: Side, cursor: BiometricProfilePage.Cursor?) async throws -> BiometricProfilePage { try await demo.evaluationProfiles(side: side, cursor: cursor) }
    func evaluationProfile(id: String) async throws -> BiometricProfileRevision { try await demo.evaluationProfile(id: id) }
    func jobs(side: Side, cursor: BiometricBacktestPage.Cursor?) async throws -> BiometricBacktestPage { try await demo.jobs(side: side, cursor: cursor) }
    func job(id: String) async throws -> BiometricBacktestJob { try await demo.job(id: id) }
    func submit(_ request: BiometricBacktestSubmission) async throws -> BiometricBacktestJob { try await demo.submit(request) }
    func cancelJob(id: String) async throws -> BiometricBacktestJob { try await demo.cancelJob(id: id) }
    func experiments(side: Side, cursor: BiometricExperimentPage.Cursor?) async throws -> BiometricExperimentPage {
        let page = try await demo.experiments(side: side, cursor: cursor)
        if hold { hold = false; await withCheckedContinuation { held = $0 } }
        if duplicate { duplicate = false; return .init(items: page.items + page.items, nextCursor: page.nextCursor) }
        return page
    }
    func experiment(id: String) async throws -> BiometricExperiment { try await demo.experiment(id: id) }
    func create(_ request: BiometricExperimentRequest) async throws -> BiometricExperiment {
        sent.append(request)
        let result = try await demo.create(request)
        if lose { lose = false; throw URLError(.timedOut) }
        if mismatch { mismatch = false; return .init(id: result.id, datasetId: result.datasetId, side: .right, protocol: result.protocol, protocolHash: result.protocolHash, holdoutAccesses: 0, createdAtMs: result.createdAtMs) }
        return result
    }
    func sessions(side: Side, cursor: ReplaySessionPage.Cursor?) async throws -> ReplaySessionPage { try await demo.sessions(side: side, cursor: cursor) }
    func capabilities(side: Side, id: Int) async throws -> ReplaySessionCapabilities { try await demo.capabilities(side: side, id: id) }
    func references(side: Side, cursor: ReferenceLibraryPage.Cursor?) async throws -> ReferenceLibraryPage { try await demo.references(side: side, cursor: cursor) }
    func datasets(side: Side, cursor: BiometricDatasetPage.Cursor?) async throws -> BiometricDatasetPage { try await demo.datasets(side: side, cursor: cursor) }
    func dataset(id: String) async throws -> BiometricDataset { try await demo.dataset(id: id) }
    func create(_ request: BiometricDatasetRequest) async throws -> BiometricDataset { try await demo.create(request) }
    func release(id: String) async throws -> BiometricDataset { try await demo.release(id: id) }
    func replayAdmission() async throws -> ReplayAdmission { try await demo.replayAdmission() }
    func rawSources(startMs: Double, endMs: Double, cursor: String?) async throws -> InspectedRawPage { try await demo.rawSources(startMs: startMs, endMs: endMs, cursor: cursor) }
    func inspectRaw(afterName: String?) async throws -> RawInspectionResult { try await demo.inspectRaw(afterName: afterName) }
    func createWaveform(_ request: WaveformDatasetRequest) async throws -> WaveformDatasetResponse { try await demo.createWaveform(request) }
}
