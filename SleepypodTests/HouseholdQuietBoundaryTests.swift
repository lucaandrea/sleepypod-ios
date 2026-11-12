import XCTest
import FreeSleepKit
@testable import Sleepypod

@MainActor final class HouseholdQuietBoundaryTests: XCTestCase {
    private func setup() async throws -> (HouseholdWorkspace, HouseholdTestServer, PersonalQuietPreviewServer, HouseholdTestVault) {
        let quiet = try PersonalQuietPreviewServer(mode: "uncertain"), server = try HouseholdTestServer()
        try await server.useSession(quiet.account)
        let record = HouseholdConnectionRecord(id: UUID(), endpoint: URL(string: "https://quiet.invalid")!,
            deviceSecret: String(repeating: "A", count: 43), identity: quiet.account)
        let vault = HouseholdTestVault()
        vault.state = .init(connections: [record], selected: record.id)
        let defaults = UserDefaults(suiteName: "quiet-boundary-\(UUID().uuidString)")!
        defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
        let model = HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in server }, quietClient: { _ in quiet },
            capability: { false }, ownerEndpoint: { nil }, ownerKey: { _ in "" })
        await model.refresh()
        XCTAssertNotNil(model.quiet, model.error ?? "Quiet workspace missing")
        return (model, server, quiet, vault)
    }
    func testBackgroundKeepsReceiptButHidesStateThenReconcilesWithoutResend() async throws {
        let (model, _, server, _) = try await setup()
        let quiet = try XCTUnwrap(model.quiet)
        await quiet.refresh(); await quiet.change(minutes: 60)
        let request = try XCTUnwrap(quiet.pending)
        await model.sceneChanged(active: false)
        XCTAssertNil(quiet.currentPage); XCTAssertFalse(quiet.enabled); XCTAssertEqual(quiet.pending, request)
        await model.sceneChanged(active: true)
        XCTAssertTrue(model.quiet === quiet); XCTAssertTrue(quiet.enabled); XCTAssertEqual(quiet.pending, request)
        await quiet.refresh(); XCTAssertFalse(quiet.editable)
        await quiet.reconcile()
        XCTAssertNil(quiet.pending); XCTAssertNotNil(quiet.currentPage?.mine.until)
        let count = await server.writeCount; XCTAssertEqual(count, 1)
    }
    func testFailedParentRefreshPreservesUncertainReceiptUntilSameAccountReturns() async throws {
        let (model, server, _, _) = try await setup()
        let quiet = try XCTUnwrap(model.quiet)
        await quiet.refresh(); await quiet.change(minutes: 60)
        let pending = quiet.pending
        await server.failNext(.uncertain); await model.refresh()
        XCTAssertNil(model.session); XCTAssertFalse(quiet.enabled); XCTAssertEqual(quiet.pending, pending)
        await model.refresh()
        XCTAssertTrue(model.quiet === quiet); XCTAssertTrue(quiet.enabled)
        await quiet.reconcile(); XCTAssertNil(quiet.pending)
    }
    func testSignOutInvalidatesQuietAndRemovesRequestFromVisibleSession() async throws {
        let (model, _, _, _) = try await setup()
        let quiet = try XCTUnwrap(model.quiet)
        await quiet.refresh(); await quiet.change(minutes: 60)
        XCTAssertNotNil(quiet.pending)
        model.signOut()
        XCTAssertNil(model.quiet); XCTAssertTrue(quiet.isInvalidated)
        XCTAssertNil(quiet.pending); XCTAssertNil(quiet.currentPage)
    }
    func testChangedRevisionDisposesOldQuietReceiptAndAccess() async throws {
        let (model, server, _, _) = try await setup()
        let quiet = try XCTUnwrap(model.quiet)
        let changed = try PersonalHistoryFixtures.changed(quiet.connection.session) { object in
            object["householdRevision"] = (object["householdRevision"] as! Int) + 1
        }
        try await server.useSession(changed); await model.refresh()
        XCTAssertTrue(quiet.isInvalidated); XCTAssertFalse(model.quiet === quiet)
        XCTAssertEqual(model.quiet?.connection.session, changed)
    }
    func testRevokedParentConnectionForgetsQuietAndPairing() async throws {
        let (model, server, _, vault) = try await setup()
        let quiet = try XCTUnwrap(model.quiet)
        await server.failNext(.authentication); await model.refresh()
        XCTAssertNil(model.quiet); XCTAssertTrue(quiet.isInvalidated)
        XCTAssertNil(vault.state.selected); XCTAssertTrue(vault.state.connections.isEmpty)
    }
    func testAccountSwitchCannotReusePreviousReceiptOrCredential() async throws {
        let (model, server, _, vault) = try await setup()
        let quiet = try XCTUnwrap(model.quiet)
        await quiet.refresh(); await quiet.change(minutes: 60)
        let different = try PersonalQuietFixtures.session("memberSession")
        let other = HouseholdConnectionRecord(id: UUID(), endpoint: URL(string: "https://quiet.invalid")!,
            deviceSecret: String(repeating: "B", count: 43), identity: different)
        vault.state.connections.append(other)
        // A second workspace restores the saved account inventory before selection.
        let defaults = UserDefaults(suiteName: "quiet-switch-\(UUID().uuidString)")!
        defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
        let restored = HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in server }, capability: { false })
        await restored.refresh()
        let previous = try XCTUnwrap(restored.quiet)
        try await server.useSession(different); await restored.select(other.id)
        XCTAssertTrue(previous.isInvalidated); XCTAssertFalse(restored.quiet === previous)
        XCTAssertEqual(restored.quiet?.connection.token, other.deviceSecret)
        XCTAssertNil(restored.quiet?.pending)
    }
    func testMaintenanceUncertaintySuspendsQuietAndConfirmedEntryInvalidatesIt() async throws {
        let account = try PersonalHistoryFixtures.changed(MaintenanceFixtures.session()) { object in
            var capabilities = object["capabilities"] as! [String: Any]
            capabilities["householdQuiet"] = true; object["capabilities"] = capabilities
        }
        let server = try HouseholdTestServer(), maintenance = try MaintenanceTestServer("empty")
        try await server.useSession(account); await maintenance.changeAccount(account)
        try await maintenance.configure(now: Int64(Date().timeIntervalSince1970 * 1_000))
        let vault = HouseholdTestVault()
        let record = HouseholdConnectionRecord(id: UUID(), endpoint: URL(string: "https://quiet.invalid")!,
            deviceSecret: String(repeating: "A", count: 43), identity: account)
        vault.state = .init(connections: [record], selected: record.id)
        let defaults = UserDefaults(suiteName: "quiet-maintenance-\(UUID().uuidString)")!
        defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
        let model = HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in server }, maintenanceClient: { _ in maintenance }, capability: { false })
        await model.refresh()
        let quiet = try XCTUnwrap(model.quiet)
        XCTAssertTrue(quiet.enabled)
        try await maintenance.configure(now: Int64(Date().timeIntervalSince1970 * 1_000) - 60_000)
        await model.refresh()
        XCTAssertTrue(model.requiresMaintenance); XCTAssertFalse(quiet.enabled)
        XCTAssertTrue(model.quiet === quiet); XCTAssertFalse(quiet.isInvalidated)
        try await maintenance.configure(key: "committed", now: Int64(Date().timeIntervalSince1970 * 1_000))
        await model.refresh()
        XCTAssertTrue(model.requiresMaintenance); XCTAssertTrue(quiet.isInvalidated); XCTAssertNil(model.quiet)
    }
}
