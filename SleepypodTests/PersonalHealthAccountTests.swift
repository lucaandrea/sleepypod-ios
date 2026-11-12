import CryptoKit
import XCTest
@testable import Sleepypod
@testable import FreeSleepKit

@MainActor final class PersonalHealthAccountTests: XCTestCase {
    private func session(enabled: Bool = true) throws -> HouseholdSession {
        try PersonalHistoryFixtures.changed(ArrangementFixtures.session()) {
            var capabilities = try XCTUnwrap($0["capabilities"] as? [String: Any])
            capabilities["healthImport"] = enabled; $0["capabilities"] = capabilities
        }
    }
    private func context(_ body: @MainActor () async throws -> Void) async rethrows {
        try await AppMode.$suppliedBackend.withValue("sleepypod-core") {
            try await PersonalWorkspaceBoundary.$suppliedActive.withValue(true, operation: body)
        }
    }
    private func storage() -> (URL, PrivateSnapshotStore) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let key = SymmetricKey(size: .bits256)
        return (directory, .init(directory: directory, namespace: "account-health-test", encryptionKey: { key }))
    }

    func testLiveSessionEnablesEnrollmentButAnOutageKeepsOnlyCachedReading() async throws {
        try await context {
            let identity = try session(), vault = ArrangementTestVault(identity), server = try ArrangementTestServer()
            await server.setSession(identity)
            let (directory, snapshots) = storage(); defer { try? FileManager.default.removeItem(at: directory) }
            let model = HouseholdWorkspace(vault: vault, healthSnapshots: snapshots, defaults: UserDefaults(suiteName: UUID().uuidString)!,
                client: { _ in server }, capability: { false }, ownerEndpoint: { nil })
            model.enter(); await model.refresh()
            let health = try XCTUnwrap(model.personalHealth)
            XCTAssertTrue(health.mayEnroll); health.enroll(confirmedOwnHealth: true)
            XCTAssertEqual(health.status, .ready)
            await server.configure(sessionFailure: .uncertain); await model.refresh()
            let cached = try XCTUnwrap(model.personalHealth)
            XCTAssertTrue(health.isInvalidated); XCTAssertEqual(cached.status, .ready); XCTAssertFalse(cached.mayImport)
            model.signOut()
            XCTAssertTrue(cached.isInvalidated); XCTAssertNil(model.personalHealth)
            let requests = await server.posts; XCTAssertTrue(requests.isEmpty)
        }
    }

    func testDisabledCapabilityAndBlockedIdentityCannotExposeEnrollment() async throws {
        for enabled in [true, false] {
            try await context {
                let identity = try session(enabled: enabled), vault = ArrangementTestVault(identity), server = try ArrangementTestServer()
                await server.setSession(identity)
                let (directory, snapshots) = storage(); defer { try? FileManager.default.removeItem(at: directory) }
                let model = HouseholdWorkspace(vault: vault, healthSnapshots: snapshots, defaults: UserDefaults(suiteName: UUID().uuidString)!,
                    client: { _ in server }, capability: { false }, ownerEndpoint: { nil })
                model.enter(); await model.refresh()
                XCTAssertEqual(model.personalHealth != nil, enabled)
                await server.configure(sessionFailure: .forbidden); await model.refresh()
                XCTAssertNil(model.personalHealth)
            }
        }
    }

    func testBackgroundAndRevocationWithdrawAccessAndEraseOnlyPersonalEnrollment() async throws {
        try await context {
            let identity = try session(), vault = ArrangementTestVault(identity), server = try ArrangementTestServer()
            await server.setSession(identity)
            let (directory, snapshots) = storage(); defer { try? FileManager.default.removeItem(at: directory) }
            let model = HouseholdWorkspace(vault: vault, healthSnapshots: snapshots, defaults: UserDefaults(suiteName: UUID().uuidString)!,
                client: { _ in server }, capability: { false }, ownerEndpoint: { nil })
            model.enter(); await model.refresh()
            let health = try XCTUnwrap(model.personalHealth); health.enroll(confirmedOwnHealth: true)
            await model.sceneChanged(active: false)
            XCTAssertTrue(health.isInvalidated); XCTAssertNil(model.personalHealth)
            await model.sceneChanged(active: true)
            XCTAssertEqual(model.personalHealth?.status, .ready)
            await server.configure(sessionFailure: .authentication); await model.refresh()
            XCTAssertNil(model.personalHealth); XCTAssertTrue(vault.state.connections.isEmpty)
            XCTAssertNil(try PersonalHealthStore(snapshots: snapshots).read())
        }
    }

    func testAccessBindingChangesWithCredentialsAndRevisionsButOwnershipDoesNotFollowTheSide() throws {
        let original = try session(), vault = ArrangementTestVault(original)
        let record = try XCTUnwrap(vault.state.connections.first)
        let first = try PersonalHealthAccess(record: record, session: original)
        let changed = try PersonalHistoryFixtures.changed(original) {
            $0["assignmentRevision"] = original.assignmentRevision + 1
            $0["self"] = ["displayName": original.person.displayName, "zones": ["right"], "assignment": "right"]
        }
        let next = HouseholdConnectionRecord(id: record.id, endpoint: record.endpoint, deviceSecret: String(repeating: "B", count: 43), identity: changed)
        let second = try PersonalHealthAccess(record: next, session: changed)
        XCTAssertEqual(first.identity, second.identity); XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.credentialRevision.contains(record.deviceSecret))
        XCTAssertThrowsError(try PersonalHealthAccess(record: record, session: changed))
    }
}
