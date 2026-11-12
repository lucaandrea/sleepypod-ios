import CryptoKit
import FreeSleepKit
import XCTest
@testable import Sleepypod

@MainActor final class PersonalRouteTests: XCTestCase {
    private let home = URL(string: "http://10.0.0.123:3000")!
    private let away = URL(string: "https://personal-away.invalid")!
    private func record() throws -> HouseholdConnectionRecord {
        .init(id: UUID(), endpoint: home, deviceSecret: String(repeating: "A", count: 43), identity: try PersonalHistoryFixtures.session())
    }
    private func enrolled() throws -> HouseholdConnectionRecord {
        var record = try record()
        record.verifiedRoutes = try .init(record: record, home: home, away: away, now: .now)
        return record
    }

    func testEnrollmentRequiresBothMatchingSessionsAndPreservesOriginalCacheScope() async throws {
        let record = try record(), session = try XCTUnwrap(record.identity)
        var reads: [URL] = [], saved: VerifiedPersonalRoutes?
        let workspace = PersonalRouteWorkspace { endpoint, key in
            reads.append(endpoint); XCTAssertEqual(key, record.deviceSecret); return session
        }
        await workspace.enroll(record: record, home: home.absoluteString, away: away.absoluteString, isCurrent: { true }, save: { saved = $0 })
        XCTAssertEqual(reads, [home, away]); XCTAssertNotNil(saved); XCTAssertFalse(workspace.busy)
        var switched = record; switched.verifiedRoutes = saved; switched.endpoint = away
        XCTAssertEqual(try PersonalOfflineLibrary.scope(record.connection(for: session)), try PersonalOfflineLibrary.scope(switched.connection(for: session)))
        let encoded = String(decoding: try JSONEncoder().encode(XCTUnwrap(saved)), as: UTF8.self)
        XCTAssertFalse(encoded.contains(record.deviceSecret))
    }

    func testInvalidOrUnrelatedAddressesFailBeforeAnyCredentialLeavesTheDevice() async throws {
        let record = try record(), session = try XCTUnwrap(record.identity)
        var reads = 0
        let workspace = PersonalRouteWorkspace { _, _ in reads += 1; return session }
        for pair in [(home.absoluteString, home.absoluteString), (home.absoluteString, "http://away.invalid"),
                     ("https://other.invalid", away.absoluteString), (home.absoluteString, "https://user:pass@away.invalid") ] {
            await workspace.enroll(record: record, home: pair.0, away: pair.1, isCurrent: { true }, save: { _ in XCTFail("Must not enroll") })
        }
        XCTAssertEqual(reads, 0)
    }

    func testDifferentPeoplePodsAndChangingRevisionsCannotEnroll() async throws {
        let record = try record(), session = try XCTUnwrap(record.identity)
        for field in ["podId", "householdId", "accountId", "selfSleeperId", "sessionRevision", "assignmentRevision"] {
            let other = try PersonalHistoryFixtures.changed(session) { value in
                if field.hasSuffix("Revision") { value[field] = 2 } else { value[field] = UUID().uuidString }
            }
            let workspace = PersonalRouteWorkspace { endpoint, _ in endpoint == self.home ? session : other }
            await workspace.enroll(record: record, home: home.absoluteString, away: away.absoluteString, isCurrent: { true }, save: { _ in XCTFail(field) })
            XCTAssertEqual(workspace.lastFailure, .changedIdentity)
        }
    }

    func testEnrollmentDiscardedAfterSelectionChangeOrCancellation() async throws {
        let record = try record(), session = try XCTUnwrap(record.identity)
        var current = true, reads = 0
        let workspace = PersonalRouteWorkspace { _, _ in current = false; reads += 1; return session }
        await workspace.enroll(record: record, home: home.absoluteString, away: away.absoluteString, isCurrent: { current }, save: { _ in XCTFail("Late enrollment") })
        XCTAssertEqual(reads, 1)
        let cancelled = PersonalRouteWorkspace { _, _ in throw CancellationError() }
        await cancelled.enroll(record: record, home: home.absoluteString, away: away.absoluteString, isCurrent: { true }, save: { _ in XCTFail("Cancelled enrollment") })
        XCTAssertFalse(cancelled.busy)
    }

    func testNetworkFailureSwitchesOnlyToVerifiedPersonalIdentity() async throws {
        let record = try enrolled(), session = try XCTUnwrap(record.identity)
        var reads: [URL] = [], activated: URL?
        let workspace = PersonalRouteWorkspace { endpoint, _ in
            reads.append(endpoint)
            if endpoint == self.home { throw URLError(.notConnectedToInternet) }
            return session
        }
        let verified = await workspace.resolve(record: record, isCurrent: { true }, activate: { activated = $0 })
        XCTAssertTrue(verified); XCTAssertEqual(reads, [home, away]); XCTAssertEqual(activated, away)
        XCTAssertEqual(workspace.verifiedEndpoint, away)
    }

    func testNetworkOnlyFallbackAndNoReplayAfterAuthenticationTlsOrControllerFailure() async throws {
        let record = try enrolled(), session = try XCTUnwrap(record.identity)
        let failures: [Error] = [HouseholdFailure.authentication, HouseholdFailure.forbidden, HouseholdFailure.unavailable,
            HouseholdFailure.invalid, HouseholdFailure.rateLimited, HouseholdFailure.uncertain,
            URLError(.serverCertificateUntrusted), URLError(.secureConnectionFailed), URLError(.cancelled), PersonalRouteFailure.freshness]
        for failure in failures {
            var reads = 0
            let workspace = PersonalRouteWorkspace { _, _ in reads += 1; throw failure }
            let result = await workspace.resolve(record: record, isCurrent: { true }, activate: { _ in XCTFail("Must not switch") })
            XCTAssertFalse(result); XCTAssertEqual(reads, 1)
        }
        let other = try PersonalHistoryFixtures.changed(session) { $0["accountId"] = UUID().uuidString }
        var reads = 0
        let workspace = PersonalRouteWorkspace { _, _ in reads += 1; return other }
        let result = await workspace.resolve(record: record, isCurrent: { true }, activate: { _ in XCTFail("Wrong account") })
        XCTAssertFalse(result); XCTAssertEqual(reads, 1); XCTAssertEqual(workspace.lastFailure, .changedIdentity)
    }

    func testHealthyCurrentConnectionAndDisabledProfileNeverSwitch() async throws {
        var record = try enrolled(); let session = try XCTUnwrap(record.identity)
        var reads = 0
        let workspace = PersonalRouteWorkspace { endpoint, _ in reads += 1; XCTAssertEqual(endpoint, self.home); return session }
        let first = await workspace.resolve(record: record, isCurrent: { true }, activate: { _ in XCTFail("Already connected") })
        XCTAssertTrue(first); XCTAssertEqual(reads, 1)
        record.verifiedRoutes?.enabled = false
        let disabled = await workspace.resolve(record: record, isCurrent: { true }, activate: { _ in XCTFail("Disabled") })
        XCTAssertFalse(disabled); XCTAssertEqual(reads, 1)
    }

    func testSecureSaveFailureAndLateIdentityChangeCannotActivate() async throws {
        let record = try enrolled(), session = try XCTUnwrap(record.identity)
        let workspace = PersonalRouteWorkspace { endpoint, _ in
            if endpoint == self.home { throw URLError(.timedOut) }; return session
        }
        let result = await workspace.resolve(record: record, isCurrent: { true }, activate: { _ in throw HouseholdFailure.storage })
        XCTAssertFalse(result); XCTAssertNil(workspace.verifiedEndpoint); XCTAssertEqual(workspace.lastFailure, .storage)
        var current = true
        let late = PersonalRouteWorkspace { _, _ in current = false; return session }
        let stale = await late.resolve(record: record, isCurrent: { current }, activate: { _ in XCTFail("Changed account") })
        XCTAssertFalse(stale); XCTAssertNil(late.verifiedEndpoint)
    }

    func testCacheSharingRequiresOriginalKeyPersonConnectionAndEnrolledOrigin() throws {
        let record = try enrolled(), session = try XCTUnwrap(record.identity)
        let profile = try XCTUnwrap(record.verifiedRoutes)
        for connection in [
            PersonalBedConnection(id: UUID(), endpoint: home, token: record.deviceSecret, session: session, verifiedRoutes: profile),
            .init(id: record.id, endpoint: home, token: String(repeating: "B", count: 43), session: session, verifiedRoutes: profile),
            .init(id: record.id, endpoint: URL(string: "https://unrelated.invalid")!, token: record.deviceSecret, session: session, verifiedRoutes: profile),
            .init(id: record.id, endpoint: home, token: record.deviceSecret,
                session: try PersonalHistoryFixtures.changed(session) { $0["selfSleeperId"] = UUID().uuidString }, verifiedRoutes: profile)
        ] { XCTAssertThrowsError(try PersonalOfflineLibrary.scope(connection)) }
    }

    func testExistingEncryptedLibrarySurvivesVerifiedHomeAwaySwitch() throws {
        let record = try enrolled(), session = try XCTUnwrap(record.identity)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let snapshots = PrivateSnapshotStore(directory: directory, namespace: "personal-route-test", encryptionKey: { key })
        let store = PersonalOfflineLibraryStore(snapshots: snapshots)
        var original = record; original.verifiedRoutes = nil
        try store.save(PersonalHistoryFixtures.page(), appending: false, connection: original.connection(for: session), receivedAt: 1_793_397_600_000)
        var awayRecord = record; awayRecord.endpoint = away
        XCTAssertNotNil(try store.read(connection: awayRecord.connection(for: session), now: 1_793_397_600_000))
    }
}
