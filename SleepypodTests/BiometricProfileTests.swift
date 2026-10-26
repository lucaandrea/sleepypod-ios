import XCTest
@testable import Sleepypod

@MainActor final class BiometricProfileTests: XCTestCase {
    func testCurrentReceiptAgesOutBetweenPolls() {
        let component = BiometricRuntimeHealth.Component(component: "heart_rate", generation: 4, state: "current", ageMs: 119000)
        let health = BiometricRuntimeHealth(state: "current", staleAfterMs: 120000, components: [component])
        XCTAssertEqual(health.state(after: 1000), "current")
        XCTAssertEqual(health.state(after: 1001), "stale")
        XCTAssertEqual(health.state(component, after: 1001), "stale")
        XCTAssertEqual(health.state(after: -1), "unreported")
    }
    func testManifestDrivesBoundsAndCandidateEditsDoNotApply() async throws {
        let client = DemoBiometricProfilesClient(), store = BiometricProfilePendingStore(directory: nil)
        let workspace = BiometricProfilesWorkspace(side: .left, client: client, pendingStore: store)
        let draft = BiometricCandidateWorkspace(profile: workspace, parentID: nil)
        await draft.load(); XCTAssertNil(draft.error); XCTAssertEqual(draft.parameters.count, 6); XCTAssertFalse(draft.dirty)
        draft.setNumber("heart_rate.trackingHistoryLength", value: 1.5)
        XCTAssertNotNil(draft.validation); await draft.review(); XCTAssertNil(draft.resolution)
        draft.setNumber("heart_rate.trackingHistoryLength", value: 6)
        draft.setNumber("heart_rate.trackingToleranceBpm", value: .nan)
        XCTAssertNotNil(draft.validation)
        draft.setNumber("heart_rate.trackingToleranceBpm", value: nil)
        await draft.review(); XCTAssertNotNil(draft.resolution); XCTAssertNotNil(draft.request)
        draft.setNumber("heart_rate.trackingHistoryLength", value: 7)
        XCTAssertNil(draft.resolution); XCTAssertNil(draft.request)
        await draft.review(); await draft.save()
        XCTAssertNotNil(draft.saved); XCTAssertNil(workspace.pending)
        let current = try await client.overview(side: .left)
        XCTAssertEqual(current.desired.binding.generation, 0); XCTAssertTrue(current.desired.isDefault)
    }
    func testStageOverrideRemovalPreservesOtherExplicitParameters() async throws {
        let client = DemoBiometricProfilesClient(), workspace = BiometricProfilesWorkspace(side: .right, client: client, pendingStore: .init(directory: nil))
        let draft = BiometricCandidateWorkspace(profile: workspace, parentID: nil); await draft.load()
        let original = try XCTUnwrap(draft.stage)
        var changed = original; changed.fallback = .wake; draft.setStage(changed, path: "fallback")
        draft.setNumber("hrv_index.minimumWindows", value: 15)
        XCTAssertEqual(try draft.overrides().count, 2)
        draft.removeStageOverride("fallback")
        XCTAssertEqual(draft.stage?.fallback, original.fallback)
        XCTAssertEqual(try draft.overrides().map(\.path), ["hrv_index.minimumWindows"])
    }
    func testSameResolvedValueStillReportsChangedOverrideIntent() async throws {
        let client = DemoBiometricProfilesClient(), manifest = try await client.manifest()
        let request = BiometricCandidateRequest(side: .left, parentRevisionId: nil, baseManifestHash: manifest.manifestHash, overrides: [.init(path: "heart_rate.trackingToleranceBpm", value: .number(15))], origin: "manual", requester: "test", idempotencyKey: UUID().uuidString)
        let revision = try await client.create(request)
        let diff = try await client.compare(side: .left, revisionId: revision.id, againstRevisionId: nil)
        XCTAssertTrue(diff.changes.isEmpty); XCTAssertEqual(diff.beforeHash, diff.afterHash)
        XCTAssertEqual(diff.intentChangedPaths, ["heart_rate.trackingToleranceBpm"])
        let compatibility = try await client.compatibility(side: .left, id: revision.id)
        XCTAssertTrue(compatibility.compatible); XCTAssertEqual(compatibility.evidence, "not_checked")
    }
    func testActivationUsesTargetHashAndDoesNotImplyProcessorAdoption() async throws {
        let client = DemoBiometricProfilesClient(), workspace = BiometricProfilesWorkspace(side: .left, client: client, pendingStore: .init(directory: nil))
        let candidate = BiometricCandidateWorkspace(profile: workspace, parentID: nil); await candidate.load()
        candidate.setNumber("heart_rate.trackingToleranceBpm", value: 20); await candidate.review(); await candidate.save()
        let revision = try XCTUnwrap(candidate.saved)
        await workspace.compare(action: .activate, target: revision.id)
        XCTAssertTrue(workspace.canApplyReview); XCTAssertEqual(workspace.review?.afterHash, revision.resolvedHash)
        await workspace.applyReviewed(boundary: .nextSession)
        XCTAssertNil(workspace.mutationError); XCTAssertNil(workspace.pending)
        XCTAssertEqual(workspace.event?.nextHash, revision.resolvedHash)
        XCTAssertEqual(workspace.activation?.observedState, "pending_delivery")
        XCTAssertEqual(workspace.overview?.runtimeHealth.state, "unreported")
        XCTAssertTrue(workspace.overview?.receipts.isEmpty == true)
        XCTAssertFalse(workspace.isFresh(at: .now.addingTimeInterval(16)))
        XCTAssertFalse(workspace.isFresh(at: .now.addingTimeInterval(-30)))
    }
    func testResetOmitsRevisionButRollbackToDefaultsSendsNull() throws {
        func request(_ action: BiometricProfileAction) -> BiometricActivationRequest {
            .init(action: action, side: .right, revisionId: nil, expectedGeneration: 4, expectedResolvedHash: String(repeating: "a", count: 64), boundary: .immediate, requester: "test", idempotencyKey: "stable-request", allowUnvalidated: true)
        }
        let reset = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request(.reset).body)) as? [String: Any])
        let rollback = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request(.rollback).body)) as? [String: Any])
        XCTAssertNil(reset["revisionId"]); XCTAssertTrue(rollback["revisionId"] is NSNull)
        XCTAssertNil(reset["action"]); XCTAssertEqual(reset["side"] as? String, "right")
        XCTAssertEqual(reset["expectedGeneration"] as? Int, 4)
        XCTAssertEqual(reset["boundary"] as? String, "immediate")
    }
    func testRetainedRequestSurvivesRelaunchAndIsIsolatedByControllerAndSide() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = BiometricCandidateRequest(side: .left, parentRevisionId: nil, baseManifestHash: String(repeating: "b", count: 64), overrides: [], origin: "manual", requester: "test", idempotencyKey: UUID().uuidString)
        let retained = BiometricProfilePending.candidate(input, expectedHash: String(repeating: "a", count: 64))
        try BiometricProfilePendingStore(directory: directory).write(retained, scope: "https://one.invalid", side: .left)
        let reopened = BiometricProfilePendingStore(directory: directory)
        XCTAssertEqual(try reopened.read(scope: "https://one.invalid", side: .left), retained)
        XCTAssertNil(try reopened.read(scope: "https://one.invalid", side: .right))
        XCTAssertNil(try reopened.read(scope: "https://two.invalid", side: .left))
        try reopened.remove(retained, scope: "https://one.invalid", side: .left)
        XCTAssertNil(try reopened.read(scope: "https://one.invalid", side: .left))
    }
    func testAnotherWorkspaceCannotReplaceOrEraseAnUnresolvedRequest() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = BiometricProfilePendingStore(directory: directory), second = BiometricProfilePendingStore(directory: directory)
        func request() -> BiometricProfilePending {
            .candidate(.init(side: .left, parentRevisionId: nil, baseManifestHash: "manifest", overrides: [], origin: "manual", requester: "test", idempotencyKey: UUID().uuidString), expectedHash: "hash")
        }
        let original = request(), replacement = request(), scope = "https://one.invalid"
        try first.write(original, scope: scope, side: .left)
        XCTAssertThrowsError(try second.write(replacement, scope: scope, side: .left))
        try first.remove(original, scope: scope, side: .left)
        try second.write(replacement, scope: scope, side: .left)
        XCTAssertThrowsError(try first.remove(original, scope: scope, side: .left))
        XCTAssertThrowsError(try first.discardUnreadable(scope: scope, side: .left))
        XCTAssertEqual(try second.read(scope: scope, side: .left), replacement)
    }
}
