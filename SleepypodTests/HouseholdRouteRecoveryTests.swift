import FreeSleepKit
import XCTest
@testable import Sleepypod

@MainActor final class HouseholdRouteRecoveryTests: XCTestCase {
    private let home = URL(string: "https://home.route-workspace.invalid")!
    private let away = URL(string: "https://away.route-workspace.invalid")!

    private func fixture() throws -> (HouseholdTestVault, HouseholdConnectionRecord) {
        let values = try HouseholdTestServer.fixture()
        let session = try JSONDecoder().decode(HouseholdSession.self, from: XCTUnwrap(values["memberSession"]))
        var record = HouseholdConnectionRecord(id: UUID(), endpoint: home,
            deviceSecret: String(repeating: "A", count: 43), identity: session)
        record.verifiedRoutes = try .init(record: record, home: home, away: away, now: .now)
        let vault = HouseholdTestVault(); vault.state.connections = [record]; vault.state.selected = record.id
        return (vault, record)
    }
    private func workspace(vault: HouseholdTestVault, server: HouseholdTestServer,
                           read: @escaping PersonalRouteWorkspace.Read) -> HouseholdWorkspace {
        let defaults = UserDefaults(suiteName: "personal-route-\(UUID().uuidString)")!
        defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
        return .init(vault: vault, routeRead: read, defaults: defaults, client: { _ in server })
    }

    func testRefreshRecoversPersonalRouteAndOnlyReadsPendingOutcome() async throws {
        let (vault, record) = try fixture(), session = try XCTUnwrap(record.identity), server = try HouseholdTestServer()
        let pending = HouseholdPendingRequest(kind: .preferences, body: Data("saved-unknown-request".utf8))
        vault.state.connections[0].pending = pending
        let model = workspace(vault: vault, server: server) { endpoint, _ in
            if endpoint == self.home { throw URLError(.cannotConnectToHost) }; return session
        }
        await model.refresh()
        XCTAssertEqual(model.selected?.endpoint, away); XCTAssertEqual(model.session, session)
        XCTAssertEqual(model.pending, pending); XCTAssertEqual(vault.state.connections[0].pending, pending)
        let calls = await server.calls
        XCTAssertFalse(calls.isEmpty); XCTAssertTrue(calls.allSatisfy { $0.method == "GET" })
        XCTAssertTrue(calls.allSatisfy { $0.token == record.deviceSecret })
    }

    func testRouteActivationStorageFailurePreservesEndpointAndBlocksControls() async throws {
        let (vault, record) = try fixture(), session = try XCTUnwrap(record.identity), server = try HouseholdTestServer()
        let model = workspace(vault: vault, server: server) { endpoint, _ in
            if endpoint == self.home { throw URLError(.timedOut) }; return session
        }
        vault.reject = true
        await model.refresh()
        XCTAssertEqual(model.selected?.endpoint, home); XCTAssertEqual(vault.state.connections[0].endpoint, home)
        XCTAssertNil(model.session); XCTAssertNil(model.temperature); XCTAssertFalse(model.maySave)
        let calls = await server.calls; XCTAssertTrue(calls.isEmpty)
    }

    func testPersonalSignoutDuringReadCannotSelectAlternateOrRestoreSession() async throws {
        let (vault, record) = try fixture(), session = try XCTUnwrap(record.identity), server = try HouseholdTestServer()
        var model: HouseholdWorkspace?
        model = workspace(vault: vault, server: server) { _, _ in model?.signOut(); return session }
        await model?.refresh()
        XCTAssertNil(model?.selected); XCTAssertNil(model?.session)
        XCTAssertEqual(vault.state.connections[0].endpoint, home)
        let calls = await server.calls; XCTAssertTrue(calls.isEmpty)
    }

    func testRejectedPersonalKeyWithdrawsCachedAuthorityWithoutTryingAnotherOrigin() async throws {
        let (vault, _) = try fixture(), server = try HouseholdTestServer()
        var reads = 0
        let model = workspace(vault: vault, server: server) { _, _ in reads += 1; throw HouseholdFailure.authentication }
        await model.refresh()
        XCTAssertEqual(reads, 1); XCTAssertNil(model.session); XCTAssertNil(model.offlineLibrary)
        XCTAssertTrue(model.selected?.offlineBlocked == true); XCTAssertEqual(model.selected?.endpoint, home)
        let calls = await server.calls; XCTAssertTrue(calls.isEmpty)
    }

    func testOrdinaryOlderAccountStillRefreshesWithoutRouteProbe() async throws {
        let (vault, _) = try fixture(), server = try HouseholdTestServer()
        vault.state.connections[0].verifiedRoutes = nil
        let model = workspace(vault: vault, server: server) { _, _ in XCTFail("Not enrolled"); throw HouseholdFailure.invalid }
        await model.refresh()
        XCTAssertNotNil(model.session); XCTAssertEqual(model.selected?.endpoint, home)
    }

    func testFreshAccountRevisionRefreshesTheSameOriginWithoutLosingTheProfile() async throws {
        let (vault, record) = try fixture(), server = try HouseholdTestServer()
        var current = try XCTUnwrap(record.identity)
        let model = workspace(vault: vault, server: server) { _, _ in current }
        await model.refresh()
        current = try PersonalHistoryFixtures.changed(current) { $0["sessionRevision"] = 2 }
        try await server.useSession(current)
        await model.checkPersonalConnection()
        XCTAssertEqual(model.session?.sessionRevision, 2)
        XCTAssertEqual(model.selected?.endpoint, home); XCTAssertEqual(model.selected?.verifiedRoutes, record.verifiedRoutes)
    }
}
