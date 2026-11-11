import CryptoKit
import FreeSleepKit
import XCTest
@testable import Sleepypod

@MainActor final class OwnerDataIdentityTests: XCTestCase {
    private let original = ["sleepypod-core", "http://10.0.0.123:3000", "10.0.0.123", "owner-revision", "boundary"]

    private func profile() throws -> EnrolledOwnerRoutes {
        let home = try OwnerConnectionCandidate(address: original[1], streamAddress: "", backend: .sleepypodCore,
            token: "synthetic-home-identity-key-not-real")
        let away = try OwnerConnectionCandidate(address: "https://identity.away.invalid", streamAddress: "", backend: .sleepypodCore,
            token: "synthetic-away-identity-key-not-real")
        return try .init(routes: .init(installationID: UUID(), credentialRevision: original[3], home: home, away: away, now: .now), currentRevision: original)
    }

    func testVerifiedRouteChangePreservesOriginalIdentityAndDisabledProfiles() throws {
        var saved = try profile(), away = original
        away[1] = saved.routes.away.address; away[2] = "identity.away.invalid"
        for enabled in [true, false] {
            saved.routes.enabled = enabled
            let homeIdentity = OwnerDataIdentity.resolve(revision: original, ownerAllowed: true) { saved }
            let awayIdentity = OwnerDataIdentity.resolve(revision: away, ownerAllowed: true) { saved }
            XCTAssertEqual(homeIdentity, .owner(original))
            XCTAssertEqual(awayIdentity, homeIdentity)
            XCTAssertNotEqual(away, original, "Request guards must still see the transport change")
        }
    }

    func testNoProfileKeepsExistingStorageIdentityAndOtherAccountWithdrawsBeforeReading() {
        XCTAssertEqual(OwnerDataIdentity.resolve(revision: original, ownerAllowed: true) { nil }, .owner(original))
        let denied = OwnerDataIdentity.resolve(revision: original, ownerAllowed: false) { XCTFail("Personal account cannot read owner metadata"); return nil }
        XCTAssertEqual(denied, .noOwner)
        XCTAssertTrue(denied.canReconcileOwnership)
        XCTAssertNil(denied.revision)
    }

    func testUnavailableMetadataCannotAuthorizeDataOrCancelAnAlarmAsAnotherOwner() throws {
        let unavailable = OwnerDataIdentity.resolve(revision: original, ownerAllowed: true) { throw ControllerIdentityFailure.invalidProfile }
        XCTAssertEqual(unavailable, .unavailable)
        XCTAssertNil(unavailable.revision)
        XCTAssertFalse(unavailable.canReconcileOwnership)
        let saved = try profile()
        XCTAssertEqual(OwnerDataIdentity.resolve(revision: [], ownerAllowed: true) { saved }, .unavailable)
        for index in [1, 3, 4] {
            var changed = original; changed[index] = "different"
            XCTAssertEqual(OwnerDataIdentity.resolve(revision: changed, ownerAllowed: true) { saved }, .unavailable)
        }
    }

    func testOfflineLibrarySurvivesVerifiedTransportChangeAndWithholdsUnreadableIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let store = PrivateSnapshotStore(directory: directory, namespace: "route-offline-test", encryptionKey: { key })
        let saved = try profile()
        var transport = original, readable = true
        let identity: () -> String? = {
            let state = OwnerDataIdentity.resolve(revision: transport, ownerAllowed: true) {
                guard readable else { throw ControllerIdentityFailure.unavailable }
                return saved
            }
            return state.offlineLibraryScope
        }
        let library = OfflineLibrarySession(store: store, currentScope: identity)
        await library.refresh(client: MockClient(), timeZone: "America/Los_Angeles")
        let originalSchedules = try XCTUnwrap(library.library.schedules)
        transport[1] = saved.routes.away.address; transport[2] = "identity.away.invalid"
        library.restore()
        XCTAssertEqual(library.library.schedules?.savedAt, originalSchedules.savedAt)
        let reopened = OfflineLibrarySession(store: store, currentScope: identity)
        reopened.restore()
        XCTAssertEqual(reopened.library.schedules?.savedAt, originalSchedules.savedAt)
        readable = false
        XCTAssertNil(reopened.library.schedules)
        reopened.restore()
        readable = true; reopened.restore()
        XCTAssertEqual(reopened.library.schedules?.savedAt, originalSchedules.savedAt)
        transport[3] = "another-owner"
        XCTAssertNil(reopened.library.schedules)
    }
}
