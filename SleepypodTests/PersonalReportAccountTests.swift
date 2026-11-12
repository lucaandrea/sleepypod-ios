import CryptoKit
import XCTest
@testable import Sleepypod
@testable import FreeSleepKit

@MainActor final class PersonalReportAccountTests: XCTestCase {
    func testSharingRevalidatesPersonalSessionAndPinsScopeWithoutOwnerCredentials() async throws {
        try await context {
            let fixture = try await PersonalReportAccountFixture(); defer { fixture.remove() }
            let connection = try await fixture.workspace.connectPersonalReportSharing()
            let call = try XCTUnwrap(fixture.created.first)
            let identity = try PersonalHealthIdentity(session: fixture.identity)
            XCTAssertEqual(call.0, fixture.vault.state.connections[0].endpoint)
            XCTAssertEqual(call.1, fixture.vault.state.connections[0].deviceSecret)
            XCTAssertEqual(call.2, .personal(podID: identity.podID, householdID: identity.householdID,
                accountID: identity.accountID, sleeperID: identity.sleeperID, sessionRevision: fixture.identity.sessionRevision,
                householdRevision: fixture.identity.householdRevision, assignmentRevision: fixture.identity.assignmentRevision))
            XCTAssertTrue(connection.isCurrent())
            fixture.workspace.signOut()
            XCTAssertFalse(connection.isCurrent())
            XCTAssertNil(fixture.workspace.personalReports)
        }
    }

    func testAbsentOrFalseCapabilityNeverCreatesPersonalReportWorkspace() async throws {
        for enabled in [nil, false] as [Bool?] {
            try await context {
                let fixture = try await PersonalReportAccountFixture(enabled: enabled); defer { fixture.remove() }
                XCTAssertNil(fixture.workspace.personalReports)
                do { _ = try await fixture.workspace.connectPersonalReportSharing(); XCTFail("Disabled sharing opened") }
                catch { XCTAssertEqual(error as? MorningReportSharingFailure, .unavailable) }
                XCTAssertTrue(fixture.created.isEmpty)
            }
        }
    }

    func testOfflineReportsRemainReadableButNoNewRequestsOrSharingAreAdmitted() async throws {
        try await context {
            let fixture = try await PersonalReportAccountFixture(); defer { fixture.remove() }
            let original = try XCTUnwrap(fixture.workspace.personalReports)
            XCTAssertTrue(original.mayRequest)
            await fixture.server.configure(sessionFailure: .uncertain); await fixture.workspace.refresh()
            let cached = try XCTUnwrap(fixture.workspace.personalReports)
            XCTAssertTrue(original.isInvalidated); XCTAssertTrue(cached.available); XCTAssertFalse(cached.mayRequest)
            do { _ = try await fixture.workspace.connectPersonalReportSharing(); XCTFail("Offline sharing opened") }
            catch { XCTAssertEqual(error as? MorningReportSharingFailure, .unavailable) }
            XCTAssertTrue(fixture.created.isEmpty)
        }
    }

    func testFreshRevisionChangeWithdrawsOldWorkspaceBeforeCreatingAnyTransport() async throws {
        try await context {
            let fixture = try await PersonalReportAccountFixture(); defer { fixture.remove() }
            let reports = try XCTUnwrap(fixture.workspace.personalReports)
            let changed = try PersonalHistoryFixtures.changed(fixture.identity) { $0["assignmentRevision"] = fixture.identity.assignmentRevision + 1 }
            await fixture.server.setSession(changed)
            do { _ = try await fixture.workspace.connectPersonalReportSharing(); XCTFail("Stale sharing opened") }
            catch { XCTAssertEqual(error as? MorningReportSharingFailure, .changedAccount) }
            XCTAssertTrue(reports.isInvalidated); XCTAssertNil(fixture.workspace.personalReports)
            XCTAssertEqual(fixture.workspace.selected?.offlineBlocked, true)
            XCTAssertTrue(fixture.created.isEmpty)
        }
    }

    func testBackgroundDuringFreshReadRejectsDelayedConnectionAndCancelsAccess() async throws {
        try await context {
            let fixture = try await PersonalReportAccountFixture(); defer { fixture.remove() }
            let reports = try XCTUnwrap(fixture.workspace.personalReports)
            await fixture.server.hold("session")
            let task = Task { try await fixture.workspace.connectPersonalReportSharing() }
            await fixture.server.waitHeld()
            await fixture.workspace.sceneChanged(active: false)
            await fixture.server.release()
            do { _ = try await task.value; XCTFail("Background sharing opened") }
            catch { XCTAssertEqual(error as? MorningReportSharingFailure, .changedAccount) }
            XCTAssertTrue(reports.isInvalidated); XCTAssertTrue(fixture.created.isEmpty)
        }
    }

    func testRevocationRemovesOnlyThisAccountsReportArchiveAndDisablesOldConnection() async throws {
        try await context {
            let fixture = try await PersonalReportAccountFixture(); defer { fixture.remove() }
            let identity = try PersonalHealthIdentity(session: fixture.identity)
            let other = PersonalHealthIdentity(podID: identity.podID, householdID: identity.householdID, accountID: UUID(), sleeperID: UUID())
            let store = PersonalReportStore(snapshots: fixture.snapshots)
            _ = try store.open(other)
            let connection = try await fixture.workspace.connectPersonalReportSharing()
            await fixture.server.configure(sessionFailure: .authentication)
            do { _ = try await fixture.workspace.connectPersonalReportSharing(); XCTFail("Revoked sharing opened") }
            catch { XCTAssertEqual(error as? MorningReportSharingFailure, .authentication) }
            XCTAssertFalse(connection.isCurrent()); XCTAssertNil(try store.read(identity)); XCTAssertNotNil(try store.read(other))
            XCTAssertTrue(fixture.vault.state.connections.isEmpty)
        }
    }

    func testExplicitLocalErasureRemovesKnownPersonalReportsButPreservesOwnerSnapshot() async throws {
        try await context {
            let fixture = try await PersonalReportAccountFixture(); defer { fixture.remove() }
            let identity = try PersonalHealthIdentity(session: fixture.identity)
            try fixture.snapshots.write(["report": "owner-only"], scope: "owner")
            fixture.workspace.erasePersonalLocalData()
            XCTAssertNil(try PersonalReportStore(snapshots: fixture.snapshots).read(identity))
            XCTAssertEqual(try fixture.snapshots.read([String: String].self, scope: "owner"), ["report": "owner-only"])
            XCTAssertTrue(fixture.vault.state.connections.isEmpty)
        }
    }

    func testReportEndpointRevocationWithdrawsTheEntirePersonalWorkspace() async throws {
        try await context {
            let fixture = try await PersonalReportAccountFixture(); defer { fixture.remove() }
            let reports = try XCTUnwrap(fixture.workspace.personalReports)
            let connection = try await fixture.workspace.connectPersonalReportSharing()
            connection.authorizationFailed?(.authentication)
            XCTAssertTrue(reports.isInvalidated); XCTAssertFalse(connection.isCurrent())
            XCTAssertNil(fixture.workspace.personalReports); XCTAssertTrue(fixture.vault.state.connections.isEmpty)
        }
    }

    private func context(_ body: @MainActor () async throws -> Void) async rethrows {
        try await AppMode.$suppliedBackend.withValue("sleepypod-core") {
            try await PersonalWorkspaceBoundary.$suppliedActive.withValue(true, operation: body)
        }
    }
}

@MainActor private final class PersonalReportAccountFixture {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let identity: HouseholdSession
    let vault: ArrangementTestVault
    let server: ArrangementTestServer
    let snapshots: PrivateSnapshotStore
    private(set) var workspace: HouseholdWorkspace!
    var created: [(URL, String, MorningReportScope)] = []

    init(enabled: Bool? = true) async throws {
        identity = try PersonalHistoryFixtures.changed(ArrangementFixtures.session()) {
            var capabilities = try XCTUnwrap($0["capabilities"] as? [String: Any])
            capabilities["healthImport"] = true; capabilities["personalReports"] = true
            capabilities["personalDeviceReports"] = enabled; $0["capabilities"] = capabilities
        }
        vault = ArrangementTestVault(identity); server = try ArrangementTestServer()
        await server.setSession(identity)
        let key = SymmetricKey(size: .bits256)
        snapshots = .init(directory: directory, namespace: "personal-report-account-test", encryptionKey: { key })
        let server = server
        workspace = HouseholdWorkspace(vault: vault, healthSnapshots: snapshots, reportSnapshots: snapshots,
            defaults: UserDefaults(suiteName: UUID().uuidString)!, client: { _ in server },
            reportClient: { [weak self] endpoint, token, scope in
                self?.created.append((endpoint, token, scope)); return PersonalAccountReportTransport()
            }, capability: { false }, ownerEndpoint: { nil }, ownerKey: { _ in XCTFail("Used owner credential"); return "" })
        workspace.enter(); await workspace.refresh()
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private struct PersonalAccountReportTransport: MorningReportSharingTransport {
    func read(id: UUID) async throws -> MorningReportSharedCopy? { nil }
    func share(id: UUID, document: Data, expectedRevision: UUID?) async throws -> MorningReportSharedCopy { throw MorningReportSharingFailure.unavailable }
    func withdraw(id: UUID, expectedRevision: UUID?) async throws -> MorningReportSharedCopy { throw MorningReportSharingFailure.unavailable }
}
