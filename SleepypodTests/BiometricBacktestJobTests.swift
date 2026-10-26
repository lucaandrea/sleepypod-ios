import XCTest
@testable import Sleepypod

@MainActor final class BiometricBacktestJobTests: XCTestCase {
    func testSharedDemoCandidateUsesCoreDefaultsHashAndIntegerCursorTime() async throws {
        let work = try await fixture()
        let defaults = try await work.profiles.resolve(overrides: [], manifestHash: work.candidate.baseManifestHash)
        XCTAssertEqual(try BiometricDemoCanonicalJSON.hash(defaults.resolved), defaults.hash)
        XCTAssertEqual(try BiometricDemoCanonicalJSON.hash(work.candidate.resolved), work.candidate.resolvedHash)
        XCTAssertEqual(work.candidate.createdAtMs.rounded(), work.candidate.createdAtMs)
        let page = try await work.client.evaluationProfiles(side: .left, cursor: nil)
        XCTAssertEqual(page.items.map(\.id), [work.candidate.id])
        let job = try await work.client.submit(work.review.request)
        XCTAssertEqual(job.configurations.first { $0.label == "default" }?.hash, defaults.hash)
        XCTAssertEqual(job.state, .queued); XCTAssertEqual(job.attempt, 0)
        XCTAssertTrue(job.progress.phase.contains("no worker"))
    }
    func testFreshBaselineAndExplicitGenerationChangeDoNotRewriteSelection() async throws {
        let work = try await fixture(), draft = try XCTUnwrap(work.preparation.draft)
        XCTAssertTrue(work.preparation.fresh())
        XCTAssertFalse(work.preparation.fresh(at: try XCTUnwrap(work.preparation.observedAt).addingTimeInterval(16)))
        try await activate(work)
        await work.preparation.refresh()
        XCTAssertEqual(draft.candidate?.generation, 0)
        XCTAssertThrowsError(try work.preparation.review())
        await work.preparation.prepareCurrentBaseline()
        let revised = try work.preparation.review()
        XCTAssertEqual(revised.request.expectedBindingGeneration, 1)
        XCTAssertNotEqual(revised.request.idempotencyKey, work.review.request.idempotencyKey)
        await work.client.failOverview(); await work.preparation.refresh()
        XCTAssertFalse(work.preparation.fresh()); XCTAssertThrowsError(try work.preparation.review())
    }
    func testHoldoutAcknowledgmentBindsExactCandidateBaselineAndPartition() async throws {
        let work = try await fixture()
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(work.inputs)) as? [String: Any])
        var manifest = try XCTUnwrap(document["manifest"] as? [String: Any]), partition = try XCTUnwrap(manifest["splitProtocol"] as? [String: Any])
        var assignments = try XCTUnwrap(partition["assignments"] as? [[String: Any]])
        assignments[0]["split"] = "holdout"; partition["assignments"] = assignments; manifest["splitProtocol"] = partition; document["manifest"] = manifest
        let holdout = try JSONDecoder().decode(BiometricDataset.self, from: JSONSerialization.data(withJSONObject: document))
        let draft = BiometricBacktestSubmissionDraft(experiment: work.experiment, dataset: holdout)
        let overview = try await work.profiles.overview(side: .left)
        try draft.select(work.candidate, overview: overview)
        XCTAssertEqual(draft.availableSplits, [.holdout]); XCTAssertThrowsError(try draft.request(currentGeneration: 0))
        draft.split = .holdout; XCTAssertThrowsError(try draft.request(currentGeneration: 0))
        draft.acknowledgeHoldout(true); XCTAssertNoThrow(try draft.request(currentGeneration: 0))
        draft.split = .tuning; draft.split = .holdout
        XCTAssertFalse(draft.holdoutAcknowledged)
        draft.acknowledgeHoldout(true); try draft.select(work.candidate, overview: overview)
        XCTAssertFalse(draft.holdoutAcknowledged)
        draft.acknowledgeHoldout(true); XCTAssertThrowsError(try draft.request(currentGeneration: 1))
    }
    func testNewSubmissionRechecksBaselineBeforeRetainingOrSending() async throws {
        let work = try await fixture(); try await activate(work)
        await work.workspace.submitJob(work.review)
        let requests = await work.client.submissions(); XCTAssertTrue(requests.isEmpty)
        XCTAssertNil(work.workspace.pending); XCTAssertTrue(work.workspace.error?.contains("baseline changed") == true)
    }
    func testIncorrectReviewedReplayScopeCannotQueue() async throws {
        let work = try await fixture(), selected = work.review
        let incorrect = BiometricBacktestReview(side: selected.side, datasetId: selected.datasetId, datasetHash: selected.datasetHash,
            protocolHash: selected.protocolHash, candidateHash: selected.candidateHash, scope: .waveform, holdoutAcknowledged: false, request: selected.request)
        await work.workspace.submitJob(incorrect)
        let attempts = await work.client.submissions(); XCTAssertTrue(attempts.isEmpty)
        XCTAssertNil(work.workspace.pending); XCTAssertNotNil(work.workspace.error)
    }
    func testUnknownQueueRetriesExactGenerationEvenAfterCancellationAndInputRelease() async throws {
        let work = try await fixture(); await work.client.loseNextSubmit()
        await work.workspace.submitJob(work.review)
        XCTAssertNotNil(work.workspace.pending); XCTAssertNil(work.workspace.savedJob)
        try await activate(work)
        try await work.client.cancelCreatedJob(); _ = try await work.client.release(id: work.inputs.id)
        let reopened = BiometricDatasetWorkspace(side: .left, client: work.client, store: work.store)
        let before = await work.client.submissions(); XCTAssertEqual(before, [work.review.request])
        await reopened.retry()
        let after = await work.client.submissions(); XCTAssertEqual(after, [work.review.request, work.review.request])
        XCTAssertNil(reopened.pending); XCTAssertEqual(reopened.savedJob?.state, .cancelled)
        XCTAssertTrue(reopened.notice?.contains("does not establish execution") == true)
    }
    func testDuplicateConcurrentDemoSubmissionsResolveToOneJob() async throws {
        let work = try await fixture()
        async let first = work.client.submit(work.review.request)
        async let second = work.client.submit(work.review.request)
        let results = try await [first, second]
        XCTAssertEqual(results[0].id, results[1].id)
        let page = try await work.client.jobs(side: .left, cursor: nil); XCTAssertEqual(page.items.count, 1)
        let changed = BiometricBacktestSubmission(experimentId: work.review.request.experimentId, candidateRevisionId: work.candidate.id,
            expectedBindingGeneration: 1, split: .tuning, idempotencyKey: work.review.request.idempotencyKey)
        do { _ = try await work.client.submit(changed); XCTFail("Changed request must conflict") } catch {}
        do { _ = try await work.client.release(id: work.inputs.id); XCTFail("Active jobs retain inputs") } catch {}
    }
    func testMismatchedQueueReceiptKeepsRecoveryAndDiscardStopsStaleRetry() async throws {
        let work = try await fixture(); await work.client.mismatchNextSubmit()
        await work.workspace.submitJob(work.review)
        XCTAssertNotNil(work.workspace.pending); XCTAssertNil(work.workspace.savedJob)
        let reopened = BiometricDatasetWorkspace(side: .left, client: work.client, store: work.store)
        reopened.discardPending(); await work.workspace.retry()
        let requests = await work.client.submissions(); XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(work.workspace.error?.contains("removed or replaced") == true)
    }
    func testUnknownCancellationReconcilesWithoutRepeatingEffect() async throws {
        let work = try await fixture(); await work.workspace.submitJob(work.review)
        let job = try XCTUnwrap(work.workspace.savedJob); await work.client.loseNextCancel()
        await work.workspace.cancelJob(job)
        XCTAssertNotNil(work.workspace.pending)
        let reopened = BiometricDatasetWorkspace(side: .left, client: work.client, store: work.store)
        await reopened.inspectCancellation()
        XCTAssertNil(reopened.pending); XCTAssertEqual(reopened.jobReceipt?.state, .cancelled)
        let attempts = await work.client.cancellations(); XCTAssertEqual(attempts, 1)
    }
    func testCancellationRequestedIsNotStoppedAndTerminalReadbackAvoidsMutation() async throws {
        let work = try await fixture(); await work.workspace.submitJob(work.review)
        let queued = try XCTUnwrap(work.workspace.savedJob)
        await work.client.requestCancellationWithoutStopping()
        await work.workspace.cancelJob(queued)
        XCTAssertEqual(work.workspace.jobReceipt?.state, .cancellationRequested)
        XCTAssertTrue(work.workspace.notice?.contains("not yet confirmed") == true)
        let another = try await fixture(); await another.workspace.submitJob(another.review)
        let otherJob = try XCTUnwrap(another.workspace.savedJob)
        await another.client.finishBeforeCancellation()
        await another.workspace.cancelJob(otherJob)
        let attempts = await another.client.cancellations(); XCTAssertEqual(attempts, 0)
        XCTAssertEqual(another.workspace.jobReceipt?.state, .succeeded)
        XCTAssertTrue(another.workspace.notice?.contains("already finished") == true)
    }
    func testJobLibraryRetainsLastPageOnBadIdentityOrReadFailure() async throws {
        let work = try await fixture(); await work.workspace.submitJob(work.review)
        let library = BiometricBacktestJobLibrary(side: .left, client: work.client); await library.load()
        XCTAssertEqual(library.page?.items.count, 1)
        await work.client.duplicateNextPage(); await library.load()
        XCTAssertNotNil(library.error); XCTAssertEqual(library.page?.items.count, 1)
        let right = BiometricBacktestJobLibrary(side: .right, client: work.client); await right.load()
        XCTAssertEqual(right.page?.items.count, 0)
    }
    private struct Work {
        let client: JobTestClient
        let profiles: DemoBiometricProfilesClient
        let store: BiometricBacktestPendingStore
        let workspace: BiometricDatasetWorkspace
        let preparation: BiometricBacktestPreparation
        let inputs: BiometricDataset
        let experiment: BiometricExperiment
        let candidate: BiometricProfileRevision
        let review: BiometricBacktestReview
    }
    private func fixture() async throws -> Work {
        let profiles = DemoBiometricProfilesClient(), store = BiometricBacktestPendingStore(directory: nil)
        let client = JobTestClient(profiles: profiles)
        let manifest = try await profiles.manifest()
        let candidate = try await profiles.create(.init(side: .left, parentRevisionId: nil, baseManifestHash: manifest.manifestHash,
            overrides: [.init(path: "heart_rate.trackingToleranceBpm", value: .number(18))], origin: "manual", requester: "synthetic-test", idempotencyKey: UUID().uuidString))
        let inputs = try await client.create(.init(selection: BiometricDatasetDemoFixture.load(side: .left).snapshots[0].selection))
        let experiment = try await client.create(BiometricExperimentDraft(dataset: inputs).request())
        let preparation = BiometricBacktestPreparation(side: .left, experiment: experiment, client: client)
        await preparation.refresh(); preparation.select(candidate)
        return .init(client: client, profiles: profiles, store: store, workspace: .init(side: .left, client: client, store: store), preparation: preparation,
                     inputs: inputs, experiment: experiment, candidate: candidate, review: try preparation.review())
    }
    private func activate(_ work: Work) async throws {
        _ = try await work.profiles.activate(.init(action: .activate, side: .left, revisionId: work.candidate.id, expectedGeneration: 0,
            expectedResolvedHash: work.candidate.resolvedHash, boundary: .immediate, requester: "synthetic-test", idempotencyKey: UUID().uuidString, allowUnvalidated: true))
    }
}

private actor JobTestClient: BiometricDatasetsServing {
    nonisolated let scope = "synthetic-job-test"
    private let demo: DemoBiometricDatasetsClient
    private var sent: [BiometricBacktestSubmission] = []
    private var cancels = 0
    private var loseSubmit = false, loseCancel = false, mismatch = false, failedOverview = false, duplicate = false
    private var cancellationOnly = false, terminalBeforeCancel = false
    private var lastJob: BiometricBacktestJob?
    init(profiles: DemoBiometricProfilesClient) { demo = .init(profiles: profiles) }
    func submissions() -> [BiometricBacktestSubmission] { sent }
    func cancellations() -> Int { cancels }
    func loseNextSubmit() { loseSubmit = true }
    func loseNextCancel() { loseCancel = true }
    func mismatchNextSubmit() { mismatch = true }
    func failOverview() { failedOverview = true }
    func duplicateNextPage() { duplicate = true }
    func requestCancellationWithoutStopping() { cancellationOnly = true }
    func finishBeforeCancellation() { terminalBeforeCancel = true }
    func cancelCreatedJob() async throws { _ = try await demo.cancelJob(id: XCTUnwrap(lastJob).id) }
    func evaluationOverview(side: Side) async throws -> BiometricProfileOverview {
        if failedOverview { throw URLError(.notConnectedToInternet) }; return try await demo.evaluationOverview(side: side)
    }
    func evaluationProfiles(side: Side, cursor: BiometricProfilePage.Cursor?) async throws -> BiometricProfilePage { try await demo.evaluationProfiles(side: side, cursor: cursor) }
    func evaluationProfile(id: String) async throws -> BiometricProfileRevision { try await demo.evaluationProfile(id: id) }
    func jobs(side: Side, cursor: BiometricBacktestPage.Cursor?) async throws -> BiometricBacktestPage {
        let page = try await demo.jobs(side: side, cursor: cursor)
        if duplicate { duplicate = false; return .init(items: page.items + page.items, nextCursor: page.nextCursor) }; return page
    }
    func job(id: String) async throws -> BiometricBacktestJob {
        let result = try await demo.job(id: id)
        if terminalBeforeCancel { return try modified(result, field: "state", value: .string("succeeded")) }
        return result
    }
    func submit(_ request: BiometricBacktestSubmission) async throws -> BiometricBacktestJob {
        sent.append(request); let result = try await demo.submit(request); lastJob = result
        if loseSubmit { loseSubmit = false; throw URLError(.timedOut) }
        if mismatch { mismatch = false; return try modified(result, field: "datasetHash", value: .string(String(repeating: "b", count: 64))) }
        return result
    }
    func cancelJob(id: String) async throws -> BiometricBacktestJob {
        cancels += 1
        let result = try await demo.cancelJob(id: id)
        if loseCancel { loseCancel = false; throw URLError(.timedOut) }
        if cancellationOnly { return try modified(result, field: "state", value: .string("cancel_requested")) }
        return result
    }
    private func modified(_ job: BiometricBacktestJob, field: String, value: JSONValue) throws -> BiometricBacktestJob {
        try JSONDecoder().decode(BiometricBacktestJob.self, from: JSONEncoder().encode(JSONValue.encoded(job).replacing(at: field, with: value)))
    }
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
    func replayAdmission() async throws -> ReplayAdmission { try await demo.replayAdmission() }
    func rawSources(startMs: Double, endMs: Double, cursor: String?) async throws -> InspectedRawPage { try await demo.rawSources(startMs: startMs, endMs: endMs, cursor: cursor) }
    func inspectRaw(afterName: String?) async throws -> RawInspectionResult { try await demo.inspectRaw(afterName: afterName) }
    func createWaveform(_ request: WaveformDatasetRequest) async throws -> WaveformDatasetResponse { try await demo.createWaveform(request) }
}
