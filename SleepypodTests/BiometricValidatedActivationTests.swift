import XCTest
@testable import Sleepypod

@MainActor final class BiometricValidatedActivationTests: XCTestCase {
    func testExactRetainedReportSelectsCandidateAndDemoNeverQualifiesIt() async throws {
        let example = try XCTUnwrap(BiometricReportExample.load().first { $0.name == "signal_replay" })
        let reading = BiometricReportWorkspace(job: example.job, side: .left, client: DemoBiometricReportsClient())
        await reading.load()
        XCTAssertNotNil(reading.validatedSelection)
        let selection = try XCTUnwrap(reading.validatedSelection)
        XCTAssertEqual(selection.evaluationId, example.id)
        XCTAssertEqual(selection.expectedReportHash, example.summary.contentHash)
        XCTAssertEqual(selection.expectedResolvedHash, example.job.configurations.first { $0.label == "candidate" }?.hash)
        XCTAssertThrowsError(try BiometricValidatedSelection(side: .right, job: example.job, descriptor: example.summary))
        let demo = DemoBiometricProfilesClient(), workspace = BiometricProfilesWorkspace(side: .left, client: demo, pendingStore: .init(directory: nil))
        await workspace.prepareValidated(selection)
        XCTAssertNil(workspace.validatedReview); XCTAssertFalse(workspace.canApplyValidated)
        XCTAssertTrue(workspace.mutationError?.contains("synthetic") == true)
        await workspace.applyValidated(boundary: .nextSession)
        XCTAssertNil(workspace.event); XCTAssertNil(workspace.pending)
    }
    func testRejectedEvidenceAndFailedFreshnessCannotApply() async throws {
        let client = ValidatedFaultClient(), selection = try await client.selection()
        let workspace = BiometricProfilesWorkspace(side: .left, client: client, pendingStore: .init(directory: nil))
        await client.rejectEvidence(); await workspace.prepareValidated(selection)
        XCTAssertFalse(workspace.canApplyValidated)
        await workspace.applyValidated(boundary: .nextSession)
        var calls = await client.requests; XCTAssertTrue(calls.isEmpty)
        await client.acceptEvidence(); await workspace.prepareValidated(selection)
        XCTAssertTrue(workspace.canApplyValidated)
        let review = try XCTUnwrap(workspace.validatedReview), overview = try XCTUnwrap(workspace.overview)
        XCTAssertFalse(review.matches(overview, now: review.reviewedAt.addingTimeInterval(61)))
        await client.failReads(); await workspace.refresh()
        XCTAssertFalse(workspace.canApplyValidated)
        await workspace.applyValidated(boundary: .nextSession)
        calls = await client.requests; XCTAssertTrue(calls.isEmpty)
    }
    func testChangedGenerationDuringReviewRequiresNewReview() async throws {
        let client = ValidatedFaultClient(), selection = try await client.selection()
        let workspace = BiometricProfilesWorkspace(side: .left, client: client, pendingStore: .init(directory: nil))
        await client.changeDuringReview(); await workspace.prepareValidated(selection)
        XCTAssertNil(workspace.validatedReview); XCTAssertFalse(workspace.canApplyValidated)
        XCTAssertTrue(workspace.mutationError?.contains("changed during evidence review") == true)
        let calls = await client.requests; XCTAssertTrue(calls.isEmpty)
    }
    func testLostReplyPersistsExactRequestAndRecoversWithoutNewEvidenceReview() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ValidatedFaultClient(), selection = try await client.selection()
        let workspace = BiometricProfilesWorkspace(side: .left, client: client, pendingStore: .init(directory: directory))
        await workspace.prepareValidated(selection); await client.loseReply()
        await workspace.applyValidated(boundary: .nextSession)
        guard case .validated(let retained) = workspace.pending else { return XCTFail("Missing durable validated request") }
        XCTAssertEqual(retained.review.selection, selection)
        await client.rejectEvidence()
        let restored = BiometricProfilesWorkspace(side: .left, client: client, pendingStore: .init(directory: directory))
        let before = await client.requests; XCTAssertEqual(before.count, 1)
        await restored.retryExactRequest()
        XCTAssertNil(restored.pending); XCTAssertEqual(restored.event?.generation, 1)
        XCTAssertEqual(restored.event?.evaluationId, selection.evaluationId)
        let calls = await client.requests; XCTAssertEqual(calls, [retained, retained])
        let reviews = await client.reviewCount; XCTAssertEqual(reviews, 1)
        let history = try await client.history(side: .left, beforeGeneration: nil); XCTAssertEqual(history.items.count, 1)
    }
    func testWrongReceiptRemainsUnconfirmedAndRemovedRequestCannotBeRetried() async throws {
        let client = ValidatedFaultClient(), selection = try await client.selection(), store = BiometricProfilePendingStore(directory: nil)
        let workspace = BiometricProfilesWorkspace(side: .left, client: client, pendingStore: store)
        await workspace.prepareValidated(selection); await client.corruptReceipt()
        await workspace.applyValidated(boundary: .immediate)
        let pending = try XCTUnwrap(workspace.pending)
        XCTAssertNil(workspace.event); XCTAssertTrue(workspace.mutationError?.contains("receipt") == true)
        try store.remove(pending, scope: client.scope, side: .left)
        await workspace.retryExactRequest()
        let calls = await client.requests; XCTAssertEqual(calls.count, 1)
    }
    func testInFlightOverviewCannotBeApplied() async throws {
        let client = ValidatedFaultClient(), selection = try await client.selection()
        let workspace = BiometricProfilesWorkspace(side: .left, client: client, pendingStore: .init(directory: nil))
        await workspace.prepareValidated(selection); await client.holdRead()
        let refresh = Task { await workspace.refresh() }
        await client.waitForHeldRead()
        XCTAssertTrue(workspace.refreshing); XCTAssertFalse(workspace.canApplyValidated)
        await workspace.applyValidated(boundary: .immediate)
        let calls = await client.requests; XCTAssertTrue(calls.isEmpty)
        await client.releaseRead(); await refresh.value
    }
}

private actor ValidatedFaultClient: BiometricProfilesServing {
    nonisolated let scope = "validated-tests.invalid"
    private let demo = DemoBiometricProfilesClient()
    private var accepted = true, readsFail = false, changeBinding = false, loseResult = false, invalidReceipt = false
    private var heldRead = false, readContinuation: CheckedContinuation<Void, Never>?
    private var readObserver: CheckedContinuation<Void, Never>?
    func waitForHeldRead() async { if readContinuation == nil { await withCheckedContinuation { readObserver = $0 } } }
    private var receipts: [String: BiometricActivationEvent] = [:]
    private(set) var requests: [BiometricValidatedRequest] = []
    private(set) var reviewCount = 0
    func rejectEvidence() { accepted = false }
    func acceptEvidence() { accepted = true }
    func failReads() { readsFail = true }
    func changeDuringReview() { changeBinding = true }
    func loseReply() { loseResult = true }
    func corruptReceipt() { invalidReceipt = true }
    func holdRead() { heldRead = true }
    func releaseRead() { heldRead = false; readContinuation?.resume(); readContinuation = nil }
    func selection() async throws -> BiometricValidatedSelection {
        let manifest = try await demo.manifest()
        let revision = try await demo.create(.init(side: .left, parentRevisionId: nil, baseManifestHash: manifest.manifestHash, overrides: [], origin: "unit-fixture", requester: "unit-fixture", idempotencyKey: UUID().uuidString))
        return .init(side: .left, revisionId: revision.id, expectedResolvedHash: revision.resolvedHash, evaluationId: UUID().uuidString, expectedReportHash: String(repeating: "a", count: 64))
    }
    func reviewValidated(_ request: BiometricValidatedReviewRequest) async throws -> BiometricValidatedEligibility {
        _ = try request.query(); reviewCount += 1
        if changeBinding {
            changeBinding = false
            let current = try await demo.overview(side: .left)
            _ = try await demo.activate(.init(action: .reset, side: .left, revisionId: nil, expectedGeneration: current.desired.binding.generation, expectedResolvedHash: current.desired.hash, boundary: .immediate, requester: "concurrent-test", idempotencyKey: UUID().uuidString, allowUnvalidated: true))
        }
        return .init(eligible: accepted)
    }
    func activateValidated(_ request: BiometricValidatedRequest) async throws -> BiometricActivationEvent {
        _ = try request.body(); requests.append(request)
        if let receipt = receipts[request.idempotencyKey] { return receipt }
        guard accepted else { throw APIError.serverError(message: "Evidence is unavailable") }
        let selection = request.review.selection
        let manual = try await demo.activate(.init(action: .activate, side: request.side, revisionId: selection.revisionId, expectedGeneration: request.review.expectedGeneration, expectedResolvedHash: selection.expectedResolvedHash, boundary: request.boundary, requester: request.requester, idempotencyKey: request.idempotencyKey, allowUnvalidated: true))
        let event = BiometricActivationEvent(id: manual.id, side: manual.side, generation: manual.generation, action: manual.action, previousRevisionId: manual.previousRevisionId, nextRevisionId: manual.nextRevisionId, previousHash: manual.previousHash, nextHash: manual.nextHash, evaluationId: selection.evaluationId, evidence: .object(["status": .string("validated_reference_agreement"), "version": .string("verified-evaluation-v1"), "reportHash": .string(invalidReceipt ? String(repeating: "b", count: 64) : selection.expectedReportHash), "revisionId": .string(selection.revisionId), "resolvedHash": .string(selection.expectedResolvedHash)]), requester: request.requester, state: manual.state, reason: manual.reason, createdAtMs: manual.createdAtMs, updatedAtMs: manual.updatedAtMs)
        receipts[request.idempotencyKey] = event
        if loseResult { loseResult = false; throw URLError(.timedOut) }
        return event
    }
    func overview(side: Side) async throws -> BiometricProfileOverview {
        if heldRead { await withCheckedContinuation { readContinuation = $0; readObserver?.resume(); readObserver = nil } }
        if readsFail { throw URLError(.notConnectedToInternet) }
        return try await demo.overview(side: side)
    }
    func activationStatus(side: Side, id: String?) async throws -> BiometricActivationStatus { try await demo.activationStatus(side: side, id: id) }
    func history(side: Side, beforeGeneration: Int?) async throws -> BiometricActivationPage { await demo.history(side: side, beforeGeneration: beforeGeneration) }
    func profiles(side: Side, cursor: BiometricProfilePage.Cursor?) async throws -> BiometricProfilePage { await demo.profiles(side: side, cursor: cursor) }
    func profile(id: String) async throws -> BiometricProfileRevision { try await demo.profile(id: id) }
    func manifest() async throws -> BiometricProfileManifest { try await demo.manifest() }
    func resolve(overrides: [BiometricOverride], manifestHash: String) async throws -> BiometricProfileResolution { try await demo.resolve(overrides: overrides, manifestHash: manifestHash) }
    func compatibility(side: Side, id: String) async throws -> BiometricProfileCompatibility { try await demo.compatibility(side: side, id: id) }
    func create(_ request: BiometricCandidateRequest) async throws -> BiometricProfileRevision { try await demo.create(request) }
    func activate(_ request: BiometricActivationRequest) async throws -> BiometricActivationEvent { try await demo.activate(request) }
    func compare(side: Side, revisionId: String?, againstRevisionId: String?) async throws -> BiometricProfileDiff { try await demo.compare(side: side, revisionId: revisionId, againstRevisionId: againstRevisionId) }
}
