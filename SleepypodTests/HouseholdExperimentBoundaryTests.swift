import XCTest
import FreeSleepKit
@testable import Sleepypod

@MainActor final class HouseholdExperimentBoundaryTests: XCTestCase {
    private func setup() async throws -> (HouseholdWorkspace, HouseholdTestServer, ComfortExperimentTestServer, HouseholdTestVault) {
        let session = try ComfortExperimentFixtures.session(), server = try HouseholdTestServer()
        try await server.useSession(session)
        let experiments = try ComfortExperimentTestServer()
        await experiments.setNow(Int64(Date().timeIntervalSince1970 * 1000))
        let record = HouseholdConnectionRecord(id: UUID(), endpoint: try XCTUnwrap(URL(string: "https://comparisons.invalid")),
            deviceSecret: String(repeating: "A", count: 43), identity: session)
        let vault = HouseholdTestVault(); vault.state = .init(connections: [record], selected: record.id)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "experiment-boundary-\(UUID().uuidString)"))
        defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
        let model = HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in server }, experimentClient: { _ in experiments },
            capability: { false }, ownerEndpoint: { nil }, ownerKey: { _ in "" })
        await model.refresh(); XCTAssertNotNil(model.experiments, model.error ?? "Comparison workspace missing")
        return (model, server, experiments, vault)
    }
    func testBackgroundHidesPersonalDataAndRecoversLostAuthorizationWithoutRepeatingIt() async throws {
        let (model, _, server, _) = try await setup(), workspace = try XCTUnwrap(model.experiments)
        let saved: ComfortExperimentDetail = try ComfortExperimentFixtures.value("saved")
        await workspace.select(saved.record.plan.id); await workspace.reviewControl()
        await server.configure(lose: "/execution/confirm"); await workspace.confirmControl()
        XCTAssertNotNil(workspace.pending)
        let writes = await server.mutations()
        await model.sceneChanged(active: false)
        XCTAssertNil(workspace.detail); XCTAssertFalse(workspace.enabled); XCTAssertNotNil(workspace.pending)
        await model.sceneChanged(active: true)
        XCTAssertTrue(model.experiments === workspace); XCTAssertTrue(workspace.enabled)
        await workspace.open()
        XCTAssertEqual(workspace.execution?.state, "admitted"); XCTAssertNil(workspace.pending)
        let after = await server.mutations(); XCTAssertEqual(after, writes)
    }
    func testSignOutAndRevocationRemoveComparisonState() async throws {
        for revoked in [false, true] {
            let (model, server, _, vault) = try await setup(), workspace = try XCTUnwrap(model.experiments)
            await workspace.open(); XCTAssertNotNil(workspace.library)
            if revoked { await server.failNext(.authentication); await model.refresh() } else { model.signOut() }
            XCTAssertNil(model.experiments); XCTAssertTrue(workspace.invalidated); XCTAssertNil(workspace.library)
            XCTAssertNil(workspace.pending)
            if revoked { XCTAssertTrue(vault.state.connections.isEmpty) }
        }
    }
    func testCapabilityWithdrawalInvalidatesExistingWorkspace() async throws {
        let (model, server, _, _) = try await setup(), workspace = try XCTUnwrap(model.experiments)
        let session = try PersonalHistoryFixtures.changed(ComfortExperimentFixtures.session()) { value in
            var capabilities = try XCTUnwrap(value["capabilities"] as? [String: Any])
            capabilities["comfortExperiments"] = false; capabilities["comfortExperimentExecution"] = false
            value["capabilities"] = capabilities
        }
        try await server.useSession(session); await model.refresh()
        XCTAssertNil(model.experiments); XCTAssertTrue(workspace.invalidated); XCTAssertFalse(workspace.enabled)
    }
}

@MainActor final class ComfortExperimentPreviewTests: XCTestCase {
    func testPracticeControlReviewKeepsOneMinuteLifetimeAcrossClockTicks() async throws {
        let clock = AdvancingExperimentClock()
        let server = try ComfortExperimentPreviewServer(mode: "ready", elapsed: { clock.next() })
        let workspace = ComfortExperimentWorkspace(client: server, now: { server.baseDate.addingTimeInterval(1) })
        await workspace.open(); await workspace.select(try XCTUnwrap(workspace.library?.experiments.first?.id))
        await workspace.reviewControl()
        let review = try XCTUnwrap(workspace.execution?.review, workspace.error ?? "Review unavailable")
        XCTAssertEqual(review.expiresAt - review.createdAt, 60_000)
        XCTAssertTrue(workspace.canConfirmControl)
    }
    func testPracticePlanningAndAuthorizationRemainSeparate() async throws {
        let server = try ComfortExperimentPreviewServer(mode: "empty")
        let workspace = ComfortExperimentWorkspace(client: server, now: { server.baseDate.addingTimeInterval(1) })
        await workspace.open(); XCTAssertTrue(workspace.library?.experiments.isEmpty == true)
        await workspace.preview(.init(firstNightDate: "2026-11-13", variantF: 69))
        XCTAssertTrue(workspace.canConfirmPlan, workspace.error ?? "No plan review")
        await workspace.savePlan(); XCTAssertEqual(workspace.execution?.state, "not_admitted", workspace.error ?? "No saved plan")
        await workspace.reviewControl(); XCTAssertTrue(workspace.canConfirmControl)
        await workspace.confirmControl(); XCTAssertEqual(workspace.execution?.state, "admitted")
        await workspace.stop(); XCTAssertEqual(workspace.detail?.record.status, "stopped"); XCTAssertEqual(workspace.execution?.state, "revoked")
    }
    func testPracticeUnknownRecoveryKeepsOriginalCommandUnconfirmed() async throws {
        let server = try ComfortExperimentPreviewServer(mode: "unknown")
        let workspace = ComfortExperimentWorkspace(client: server, now: { server.baseDate.addingTimeInterval(1) })
        await workspace.open(); await workspace.select(try XCTUnwrap(workspace.library?.experiments.first?.id))
        let application = try XCTUnwrap(workspace.execution?.applications.first, workspace.error ?? "Missing execution")
        await workspace.recover(application.id)
        XCTAssertEqual(workspace.execution?.state, "revoked", workspace.error ?? "Missing recovery")
        XCTAssertEqual(workspace.execution?.applications.first?.acknowledgment, "unconfirmed")
    }
    func testPracticeFeedbackPersistsWithoutInventingPhysicalExposure() async throws {
        let server = try ComfortExperimentPreviewServer(mode: "feedback")
        let workspace = ComfortExperimentWorkspace(client: server, now: { server.baseDate.addingTimeInterval(1) })
        await workspace.open(); await workspace.select(try XCTUnwrap(workspace.library?.experiments.first?.id))
        await workspace.saveFeedback(.init(nightDate: "2026-11-13", confirmedFullNight: true, comfort: 7, unwantedAdjustments: 2, problem: false))
        XCTAssertEqual(workspace.detail?.record.feedback.first?.comfort, 7, workspace.error ?? "Missing feedback")
        XCTAssertEqual(workspace.detail?.record.feedback.first?.unwantedAdjustments, 2)
        XCTAssertEqual(workspace.detail?.comparison.arms.variant.usable, 0)
    }
}

private final class AdvancingExperimentClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: TimeInterval = 0
    func next() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        elapsed += 0.01
        return elapsed
    }
}
