import XCTest
import FreeSleepKit
@testable import Sleepypod

@MainActor final class HouseholdMaintenanceBoundaryTests: XCTestCase {
    private func setup(_ key: String = "empty") async throws -> (HouseholdWorkspace, HouseholdTestServer, MaintenanceTestServer) {
        let server = try HouseholdTestServer(), maintenance = try MaintenanceTestServer(key)
        let account = try MaintenanceFixtures.session()
        try await server.useSession(account)
        try await maintenance.configure(now: Int64(Date().timeIntervalSince1970 * 1_000))
        let vault = HouseholdTestVault()
        let record = HouseholdConnectionRecord(id: UUID(), endpoint: URL(string: "https://household.invalid")!, deviceSecret: String(repeating: "A", count: 43), identity: account)
        vault.state.connections = [record]; vault.state.selected = record.id
        let defaults = UserDefaults(suiteName: "maintenance-boundary-\(UUID().uuidString)")!
        defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
        let reviews = try ArrangementTestServer()
        await reviews.setSession(account)
        let model = HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in server }, arrangementClient: { _ in reviews },
            maintenanceClient: { _ in maintenance }, capability: { true }, ownerEndpoint: { record.endpoint }, ownerKey: { _ in "test-owner" })
        return (model, server, maintenance)
    }

    func testInitialReadHidesEditorsUntilSavedTransitionIsKnown() async throws {
        let (model, server, maintenance) = try await setup()
        await maintenance.hold("status")
        let task = Task { await model.refresh() }
        await maintenance.waitHeld()
        XCTAssertTrue(model.requiresMaintenance); XCTAssertFalse(model.maySave)
        XCTAssertNil(model.temperature); XCTAssertNil(model.preferences); XCTAssertNil(model.arrangement)
        let before = await server.calls
        XCTAssertEqual(before.map(\.path), ["household/session"])
        await maintenance.release(); await task.value
        XCTAssertFalse(model.requiresMaintenance); XCTAssertTrue(model.maySave, model.error ?? "No parent error")
        XCTAssertNotNil(model.arrangement); XCTAssertNotNil(model.preferences)
        let posts = await maintenance.posts; XCTAssertTrue(posts.isEmpty)
    }

    func testPendingOperationBlocksAccountEditsAndOwnerEscapeButAllowsSignOut() async throws {
        let (model, server, _) = try await setup("committed")
        await model.refresh()
        XCTAssertTrue(model.requiresMaintenance); XCTAssertTrue(model.maintenance?.entered == true)
        XCTAssertNil(model.preferences); XCTAssertNil(model.routines); XCTAssertNil(model.temperature)
        await model.savePreferences(.blank); await model.invite(kind: "new_person")
        await model.returnToOwner(authenticate: { XCTFail("Owner escape must remain unavailable"); return true })
        let calls = await server.calls; XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(model.active)
        model.signOut()
        XCTAssertNil(model.maintenance); XCTAssertNil(model.session); XCTAssertNil(model.selected)
    }

    func testUnverifiableStatusKeepsGateClosedUntilFreshRead() async throws {
        let (model, _, maintenance) = try await setup()
        try await maintenance.configure(now: Int64(Date().timeIntervalSince1970 * 1_000) - 60_000)
        await model.refresh()
        XCTAssertTrue(model.requiresMaintenance); XCTAssertFalse(model.maySave); XCTAssertNil(model.preferences)
        XCTAssertNotNil(model.maintenance?.error)
        try await maintenance.configure(now: Int64(Date().timeIntervalSince1970 * 1_000))
        await model.refresh()
        XCTAssertFalse(model.requiresMaintenance); XCTAssertTrue(model.maySave)
    }

    func testBackgroundWithdrawsOrdinaryChildrenAndCanResumeSameMaintenance() async throws {
        let (model, _, maintenance) = try await setup()
        await model.refresh()
        let earlierReview = try XCTUnwrap(model.arrangement)
        let retained = try XCTUnwrap(model.maintenance)
        await model.sceneChanged(active: false)
        XCTAssertNil(model.arrangement); XCTAssertTrue(earlierReview.isInvalidated)
        XCTAssertNil(model.preferences); XCTAssertTrue(model.requiresMaintenance); XCTAssertFalse(model.maySave)
        try await maintenance.configure(now: Int64(Date().timeIntervalSince1970 * 1_000))
        await model.sceneChanged(active: true)
        XCTAssertTrue(model.maintenance === retained); XCTAssertFalse(model.requiresMaintenance)
        XCTAssertTrue(model.maySave); XCTAssertFalse(model.arrangement === earlierReview)
    }

    func testBackgroundRejectsLateInitialStatusAndRequiresAnotherRead() async throws {
        let (model, _, maintenance) = try await setup()
        await maintenance.hold("status")
        let task = Task { await model.refresh() }
        await maintenance.waitHeld()
        await model.sceneChanged(active: false)
        await maintenance.release(); await task.value
        XCTAssertTrue(model.requiresMaintenance); XCTAssertNil(model.preferences)
        XCTAssertNil(model.maintenance?.status)
        try await maintenance.configure(now: Int64(Date().timeIntervalSince1970 * 1_000))
        await model.sceneChanged(active: true)
        XCTAssertTrue(model.maySave)
    }

    func testCompletedOperationDoesNotReopenUntilExplicitReload() async throws {
        let (model, server, maintenance) = try await setup("committed")
        await model.refresh()
        let retained = try XCTUnwrap(model.maintenance)
        try await maintenance.configure(key: "completed", now: Int64(Date().timeIntervalSince1970 * 1_000))
        await model.refresh()
        XCTAssertTrue(model.requiresMaintenance); XCTAssertNil(model.preferences)
        await retained.returnToControls()
        // Completion starts a new account refresh; no mutation is required to reopen it.
        for _ in 0..<200 where model.preferences == nil { await Task.yield() }
        XCTAssertFalse(model.requiresMaintenance); XCTAssertTrue(model.maySave, model.error ?? "No parent error")
        XCTAssertFalse(model.maintenance === retained)
        let calls = await server.calls; XCTAssertTrue(calls.allSatisfy { $0.method == "GET" })
        let posts = await maintenance.posts; XCTAssertTrue(posts.isEmpty)
    }
}
