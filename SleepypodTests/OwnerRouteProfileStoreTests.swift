import CryptoKit
import FreeSleepKit
import XCTest
@testable import Sleepypod

@MainActor final class OwnerRouteProfileStoreTests: XCTestCase {
    private let homeKey = "synthetic-home-profile-credential-not-real"
    private let awayKey = "synthetic-away-profile-credential-not-real"
    private var directory: URL!
    private var encrypted: PrivateSnapshotStore!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private let revision = ["sleepypod-core", "http://10.0.0.123:3000", "10.0.0.123", "owner-revision", "owner-boundary"]

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let encryptionKey = SymmetricKey(size: .bits256)
        encrypted = .init(directory: directory, namespace: "profile-test", encryptionKey: { encryptionKey })
        defaultsName = UUID().uuidString
        defaults = UserDefaults(suiteName: defaultsName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: defaultsName)
    }

    private func key(_ address: String) -> String { address == revision[1] ? homeKey : awayKey }

    private func profile() throws -> EnrolledOwnerRoutes {
        let home = try OwnerConnectionCandidate(address: revision[1], streamAddress: "", backend: .sleepypodCore, token: homeKey)
        let away = try OwnerConnectionCandidate(address: "https://away.profile.invalid", streamAddress: "", backend: .sleepypodCore, token: awayKey)
        let routes = try VerifiedOwnerRoutes(installationID: UUID(), credentialRevision: revision[3], home: home, away: away, now: .now)
        return try .init(routes: routes, currentRevision: revision)
    }

    func testEncryptedRelaunchRetainsOriginalIdentityAcrossVerifiedOrigins() throws {
        let saved = try profile(), store = OwnerRouteProfileStore(store: encrypted, defaults: defaults, ownerAllowed: { true })
        try store.save(saved, revision: revision, key: key)
        var awayRevision = revision
        awayRevision[1] = saved.routes.away.address; awayRevision[2] = "away.profile.invalid"
        let reopened = try OwnerRouteProfileStore(store: encrypted, defaults: defaults, ownerAllowed: { true }).load(revision: awayRevision, key: key)
        XCTAssertEqual(reopened?.originalRevision, revision)
        XCTAssertEqual(reopened, saved)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: file)
            for text in [homeKey, awayKey, saved.routes.home.address, saved.routes.away.address, "owner-boundary"] {
                XCTAssertNil(bytes.range(of: Data(text.utf8)))
            }
        }
    }

    func testPersonalWorkspaceAndChangedKeysWithdrawTheProfile() throws {
        let saved = try profile()
        var ownerAllowed = true
        let store = OwnerRouteProfileStore(store: encrypted, defaults: defaults, ownerAllowed: { ownerAllowed })
        try store.save(saved, revision: revision, key: key)
        ownerAllowed = false
        XCTAssertThrowsError(try store.load(revision: revision, key: key))
        XCTAssertThrowsError(try store.save(saved, revision: revision, key: key))
        ownerAllowed = true
        XCTAssertThrowsError(try store.load(revision: revision, key: { _ in "replaced-key" }))
        XCTAssertEqual(try store.load(revision: revision, key: key), saved)
    }

    func testUnrelatedOriginsBackendsAndAccountBoundariesDoNotLoad() throws {
        let saved = try profile(), store = OwnerRouteProfileStore(store: encrypted, defaults: defaults, ownerAllowed: { true })
        try store.save(saved, revision: revision, key: key)
        for (index, replacement) in [(0, "free-sleep"), (1, "https://other.profile.invalid"), (4, "other-person-boundary")] {
            var changed = revision; changed[index] = replacement
            XCTAssertThrowsError(try store.load(revision: changed, key: key))
        }
        var differentOwner = revision; differentOwner[3] = "new-owner-key-revision"
        XCTAssertNil(try store.load(revision: differentOwner, key: key))
        XCTAssertThrowsError(try store.load(revision: [], key: key))
    }

    func testDisablingRoutingPreservesTheSameDataIdentity() throws {
        let saved = try profile(), store = OwnerRouteProfileStore(store: encrypted, defaults: defaults, ownerAllowed: { true })
        try store.save(saved, revision: revision, key: key)
        let disabled = try store.setEnabled(false, revision: revision, key: key)
        XCTAssertFalse(disabled.routes.enabled)
        XCTAssertEqual(disabled.originalRevision, saved.originalRevision)
        XCTAssertEqual(disabled.routes.profileID, saved.routes.profileID)
        let enabled = try store.setEnabled(true, revision: revision, key: key)
        XCTAssertTrue(enabled.routes.enabled)
        XCTAssertEqual(enabled.originalRevision, saved.originalRevision)
    }

    func testReenrollmentCanPreserveOnlyTheSameVerifiedInstallation() throws {
        let previous = try profile()
        var awayRevision = revision
        awayRevision[1] = previous.routes.away.address; awayRevision[2] = "away.profile.invalid"
        let renewed = try EnrolledOwnerRoutes(routes: previous.routes, currentRevision: awayRevision, previous: previous)
        XCTAssertEqual(renewed.originalRevision, revision)
        let different = try profile()
        XCTAssertThrowsError(try EnrolledOwnerRoutes(routes: different.routes, currentRevision: awayRevision, previous: previous)) { error in
            guard case ControllerIdentityFailure.differentSavedInstallation = error else { return XCTFail("Expected a changed saved controller") }
        }
    }

    func testCorruptEncryptedProfileIsUnavailableRatherThanUnconfigured() throws {
        let store = OwnerRouteProfileStore(store: encrypted, defaults: defaults, ownerAllowed: { true })
        try store.save(profile(), revision: revision, key: key)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("corrupt encrypted profile".utf8).write(to: file)
        XCTAssertThrowsError(try store.load(revision: revision, key: key))
    }

    func testMissingPreviouslyEnrolledFileCannotBecomeAnUnconfiguredOwner() throws {
        let store = OwnerRouteProfileStore(store: encrypted, defaults: defaults, ownerAllowed: { true })
        XCTAssertNil(try store.load(revision: revision, key: key))
        try store.save(profile(), revision: revision, key: key)
        try encrypted.remove(scope: revision[3])
        XCTAssertThrowsError(try store.load(revision: revision, key: key))
        var replacement = revision; replacement[3] = "new-explicit-owner-connection"
        XCTAssertNil(try store.load(revision: replacement, key: key))
    }
}
