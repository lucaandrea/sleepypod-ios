import XCTest
@testable import Sleepypod

@MainActor final class BiometricProfileLifecycleTests: XCTestCase {
    func testLostCandidateReplyRetainsExactRequestAndRetryCreatesOneRevision() async throws {
        let client = BiometricFaultClient(), store = BiometricProfilePendingStore(directory: nil)
        let workspace = BiometricProfilesWorkspace(side: .left, client: client, pendingStore: store)
        let candidate = BiometricCandidateWorkspace(profile: workspace, parentID: nil); await candidate.load()
        candidate.setNumber("heart_rate.trackingToleranceBpm", value: 19); await candidate.review()
        let request = try XCTUnwrap(candidate.request)
        await client.loseCandidateReply(); await candidate.save()
        XCTAssertNotNil(workspace.pending); XCTAssertFalse(workspace.canStartMutation)
        let restored = BiometricProfilesWorkspace(side: .left, client: client, pendingStore: store)
        await restored.retryExactRequest()
        XCTAssertNil(restored.pending); XCTAssertNil(restored.mutationError)
        let items = try await client.profiles(side: .left, cursor: nil).items
        XCTAssertEqual(items.count, 1); XCTAssertEqual(items.first?.idempotencyKey, request.idempotencyKey)
        let calls = await client.candidateRequests; XCTAssertEqual(calls, [request, request])
    }
    func testLostActivationReplyReconcilesOneGenerationWithSameIdentity() async throws {
        let client = BiometricFaultClient(), store = BiometricProfilePendingStore(directory: nil)
        let workspace = BiometricProfilesWorkspace(side: .right, client: client, pendingStore: store)
        await workspace.compare(action: .reset, target: nil)
        await client.loseActivationReply(); await workspace.applyReviewed(boundary: .immediate)
        guard case .activation(let request) = workspace.pending else { return XCTFail("Missing retained activation") }
        let restored = BiometricProfilesWorkspace(side: .right, client: client, pendingStore: store)
        await restored.retryExactRequest()
        XCTAssertEqual(restored.event?.generation, 1); XCTAssertNil(restored.pending)
        let calls = await client.activationRequests; XCTAssertEqual(calls, [request, request])
        let history = try await client.history(side: .right, beforeGeneration: nil)
        XCTAssertEqual(history.items.count, 1)
    }
    func testBindingChangedDuringComparisonCannotBecomeApplyable() async throws {
        let client = BiometricFaultClient(), workspace = BiometricProfilesWorkspace(side: .left, client: client, pendingStore: .init(directory: nil))
        await client.changeBindingAfterComparison()
        await workspace.compare(action: .reset, target: nil)
        XCTAssertNil(workspace.review); XCTAssertFalse(workspace.canApplyReview)
        XCTAssertTrue(workspace.mutationError?.contains("changed during comparison") == true)
        let requests = await client.activationRequests; XCTAssertTrue(requests.isEmpty)
    }
    func testLateStaleReviewIsRejectedByServerWithoutBlindRetry() async throws {
        let client = BiometricFaultClient(), workspace = BiometricProfilesWorkspace(side: .left, client: client, pendingStore: .init(directory: nil))
        await workspace.compare(action: .reset, target: nil)
        try await client.advanceBinding(side: .left)
        await workspace.applyReviewed(boundary: .nextSession)
        XCTAssertNotNil(workspace.pending); XCTAssertNil(workspace.event)
        let requests = await client.activationRequests; XCTAssertEqual(requests.count, 1)
        await workspace.stopRetrying()
        XCTAssertNil(workspace.pending); XCTAssertNil(workspace.review); XCTAssertEqual(workspace.overview?.desired.binding.generation, 1)
    }
    func testReadFailureRemovesFreshHealthClaimAndPreservesReport() async throws {
        let client = BiometricFaultClient(), workspace = BiometricProfilesWorkspace(side: .left, client: client, pendingStore: .init(directory: nil))
        await workspace.refresh(); XCTAssertNotNil(workspace.overview); XCTAssertTrue(workspace.isFresh())
        await client.failReads(); await workspace.refresh()
        XCTAssertNotNil(workspace.overview); XCTAssertNotNil(workspace.overviewError); XCTAssertFalse(workspace.isFresh())
    }
    func testAnOldWorkspaceCannotRetryARequestRemovedElsewhere() async throws {
        let client = BiometricFaultClient(), store = BiometricProfilePendingStore(directory: nil)
        let workspace = BiometricProfilesWorkspace(side: .left, client: client, pendingStore: store)
        let candidate = BiometricCandidateWorkspace(profile: workspace, parentID: nil); await candidate.load(); await candidate.review()
        await client.loseCandidateReply(); await candidate.save()
        let pending = try XCTUnwrap(workspace.pending)
        try store.remove(pending, scope: client.scope, side: .left)
        await workspace.retryExactRequest()
        let requests = await client.candidateRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(workspace.mutationError?.contains("changed in another workspace") == true)
    }
}

private actor BiometricFaultClient: BiometricProfilesServing {
    nonisolated let scope = "profile-tests.invalid"
    let demo = DemoBiometricProfilesClient()
    var candidateRequests: [BiometricCandidateRequest] = []
    var activationRequests: [BiometricActivationRequest] = []
    private var loseCandidate = false, loseActivation = false, changeOnCompare = false, readsFail = false
    func loseCandidateReply() { loseCandidate = true }
    func loseActivationReply() { loseActivation = true }
    func changeBindingAfterComparison() { changeOnCompare = true }
    func failReads() { readsFail = true }
    func overview(side: Side) async throws -> BiometricProfileOverview { if readsFail { throw URLError(.notConnectedToInternet) }; return try await demo.overview(side: side) }
    func activationStatus(side: Side, id: String?) async throws -> BiometricActivationStatus { try await demo.activationStatus(side: side, id: id) }
    func history(side: Side, beforeGeneration: Int?) async throws -> BiometricActivationPage { await demo.history(side: side, beforeGeneration: beforeGeneration) }
    func profiles(side: Side, cursor: BiometricProfilePage.Cursor?) async throws -> BiometricProfilePage { await demo.profiles(side: side, cursor: cursor) }
    func profile(id: String) async throws -> BiometricProfileRevision { try await demo.profile(id: id) }
    func manifest() async throws -> BiometricProfileManifest { try await demo.manifest() }
    func resolve(overrides: [BiometricOverride], manifestHash: String) async throws -> BiometricProfileResolution { try await demo.resolve(overrides: overrides, manifestHash: manifestHash) }
    func compatibility(side: Side, id: String) async throws -> BiometricProfileCompatibility { try await demo.compatibility(side: side, id: id) }
    func create(_ request: BiometricCandidateRequest) async throws -> BiometricProfileRevision {
        candidateRequests.append(request); let result = try await demo.create(request)
        if loseCandidate { loseCandidate = false; throw URLError(.timedOut) }; return result
    }
    func activate(_ request: BiometricActivationRequest) async throws -> BiometricActivationEvent {
        activationRequests.append(request); let result = try await demo.activate(request)
        if loseActivation { loseActivation = false; throw URLError(.timedOut) }; return result
    }
    func compare(side: Side, revisionId: String?, againstRevisionId: String?) async throws -> BiometricProfileDiff {
        let result = try await demo.compare(side: side, revisionId: revisionId, againstRevisionId: againstRevisionId)
        if changeOnCompare { changeOnCompare = false; try await advanceBinding(side: side) }; return result
    }
    func advanceBinding(side: Side) async throws {
        let current = try await demo.overview(side: side), diff = try await demo.compare(side: side, revisionId: nil, againstRevisionId: current.desired.binding.desiredRevisionId)
        _ = try await demo.activate(.init(action: .reset, side: side, revisionId: nil, expectedGeneration: current.desired.binding.generation, expectedResolvedHash: diff.afterHash, boundary: .immediate, requester: "concurrent-test", idempotencyKey: UUID().uuidString, allowUnvalidated: true))
    }
}
