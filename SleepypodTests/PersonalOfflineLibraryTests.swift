import CryptoKit
import FreeSleepKit
import XCTest
@testable import Sleepypod

@MainActor final class PersonalOfflineLibraryTests: XCTestCase {
    private var directory: URL!
    private var snapshots: PrivateSnapshotStore!
    private var store: PersonalOfflineLibraryStore!
    private let instant: Int64 = 1_793_397_600_000

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let key = SymmetricKey(size: .bits256)
        snapshots = .init(directory: directory, namespace: "personal-offline-test", encryptionKey: { key })
        store = .init(snapshots: snapshots)
    }
    override func tearDown() async throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    private func connection() throws -> PersonalBedConnection { PersonalHistoryFixtures.connection(try PersonalHistoryFixtures.session()) }

    func testEncryptedRoundTripPreservesIntervalsAndSeparateFreshness() throws {
        let connection = try connection(), page = try PersonalHistoryFixtures.page()
        try store.save(page, appending: false, connection: connection, receivedAt: instant)
        try store.save(PersonalHistoryFixtures.page("vitalsPage"), appending: false, connection: connection, receivedAt: instant + 100)
        let value = try XCTUnwrap(store.read(connection: connection, now: instant + 200))
        XCTAssertEqual(value.recordings[0].records, page.records)
        XCTAssertLessThan(page.records[0].startsAt, page.query.startsAt)
        XCTAssertGreaterThan(page.records[0].endsAt, page.query.endsAt)
        XCTAssertEqual(value.recordings.map(\.syncedAt), [instant, instant + 100])
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let encoded = try Data(contentsOf: XCTUnwrap(files.first))
        for forbidden in ["reportedPresenceSeconds", connection.token, connection.session.selfSleeperId] {
            XCTAssertNil(encoded.range(of: Data(forbidden.utf8)))
        }
    }

    func testOriginCredentialConnectionAndPersonChangesCannotReadAnotherCopy() throws {
        let original = try connection()
        try store.save(PersonalHistoryFixtures.page(), appending: false, connection: original, receivedAt: instant)
        let otherPerson = try PersonalHistoryFixtures.changed(original.session) { $0["accountId"] = UUID().uuidString }
        let others = [
            PersonalBedConnection(id: original.id, endpoint: URL(string: "https://other-fixture.invalid")!, token: original.token, session: original.session),
            .init(id: original.id, endpoint: original.endpoint, token: String(repeating: "B", count: 43), session: original.session),
            .init(id: UUID(), endpoint: original.endpoint, token: original.token, session: original.session),
            .init(id: original.id, endpoint: original.endpoint, token: original.token, session: otherPerson)
        ]
        for other in others { XCTAssertNil(try store.read(connection: other, now: instant)) }
        XCTAssertNotNil(try store.read(connection: original, now: instant))
    }

    func testRevisionCapabilityAndAssignmentChangesRejectTheOldLibrary() throws {
        let original = try connection()
        try store.save(PersonalHistoryFixtures.page(), appending: false, connection: original, receivedAt: instant)
        for field in ["sessionRevision", "householdRevision", "assignmentRevision", "capabilities"] {
            let session = try PersonalHistoryFixtures.changed(original.session) { value in
                if field == "capabilities" {
                    var flags = try XCTUnwrap(value[field] as? [String: Any]); flags["personalHistory"] = false; value[field] = flags
                } else { value[field] = 2 }
            }
            let changed = PersonalBedConnection(id: original.id, endpoint: original.endpoint, token: original.token, session: session)
            XCTAssertThrowsError(try store.read(connection: changed, now: instant), field)
        }
    }

    func testCiphertextCopiedAcrossScopesAndTamperingAreRejected() throws {
        let original = try connection(), other = try connection()
        try store.save(PersonalHistoryFixtures.page(), appending: false, connection: original, receivedAt: instant)
        let originalFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let originalData = try Data(contentsOf: originalFile)
        try store.save(PersonalHistoryFixtures.page(), appending: false, connection: other, receivedAt: instant)
        let otherFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0 != originalFile })
        try originalData.write(to: otherFile)
        XCTAssertThrowsError(try store.read(connection: other, now: instant))
        var corrupted = originalData; corrupted[corrupted.startIndex] ^= 1; try corrupted.write(to: originalFile)
        XCTAssertThrowsError(try store.read(connection: original, now: instant))
    }

    func testFutureAndMalformedReadsDoNotReplaceTheConfirmedCopy() throws {
        let connection = try connection(), page = try PersonalHistoryFixtures.page()
        try store.save(page, appending: false, connection: connection, receivedAt: instant)
        for field in ["generatedAt", "attributionRevision", "scope"] {
            let changed = try PersonalHistoryFixtures.changed(page) { value in
                if field == "generatedAt" { value[field] = instant + 1_000 }
                else if field == "attributionRevision" { value[field] = 0 }
                else { var scope = try XCTUnwrap(value[field] as? [String: Any]); scope["sleeperId"] = UUID().uuidString; value[field] = scope }
            }
            XCTAssertThrowsError(try store.save(changed, appending: false, connection: connection, receivedAt: instant))
            XCTAssertEqual(try store.read(connection: connection, now: instant)?.recordings.first?.syncedAt, instant)
        }
        XCTAssertThrowsError(try store.read(connection: connection, now: instant - 1))
    }

    func testFirstPageReplacesPriorRangeAndAttributionChangesWithdrawOtherKinds() throws {
        let connection = try connection()
        try store.save(PersonalHistoryFixtures.page(), appending: false, connection: connection, receivedAt: instant)
        try store.save(PersonalHistoryFixtures.page("vitalsPage"), appending: false, connection: connection, receivedAt: instant)
        let replacement = try PersonalHistoryFixtures.changed(PersonalHistoryFixtures.page("emptyPage")) { $0["attributionRevision"] = 3 }
        try store.save(replacement, appending: false, connection: connection, receivedAt: instant + 100)
        let result = try XCTUnwrap(store.read(connection: connection, now: instant + 100))
        XCTAssertEqual(result.recordings.count, 1); XCTAssertTrue(result.recordings[0].records.isEmpty)
        XCTAssertEqual(result.recordings[0].attributionRevision, 3)
    }

    func testPaginationAppendsOnlyWithinTheSameQuerySnapshotAndNeverStoresCursors() throws {
        let connection = try connection()
        let first = try PersonalHistoryFixtures.changed(PersonalHistoryFixtures.page()) { value in
            value["nextCursor"] = "opaque-private-cursor"
            var query = try XCTUnwrap(value["query"] as? [String: Any]); query["limit"] = 1; value["query"] = query
        }
        let second = try PersonalHistoryFixtures.changed(first) { value in
            value["nextCursor"] = NSNull()
            var records = try XCTUnwrap(value["records"] as? [[String: Any]]); records[0]["id"] = UUID().uuidString; value["records"] = records
        }
        XCTAssertThrowsError(try store.save(second, appending: true, connection: connection, receivedAt: instant))
        try store.save(first, appending: false, connection: connection, receivedAt: instant)
        XCTAssertThrowsError(try store.save(first, appending: true, connection: connection, receivedAt: instant))
        try store.save(second, appending: true, connection: connection, receivedAt: instant + 100)
        let value = try XCTUnwrap(store.read(connection: connection, now: instant + 100))
        XCTAssertEqual(value.recordings[0].records.count, 2); XCTAssertFalse(value.recordings[0].hasMore)
        let serialized = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        XCTAssertFalse(serialized.contains("cursor"))
        XCTAssertThrowsError(try store.save(second, appending: true, connection: connection, receivedAt: instant + 200))
    }

    func testOperatingWeekExcludesDraftAndPublicationAuthority() throws {
        let session = try PersonalRoutineFixtures.session(), review = try PersonalRoutineFixtures.review()
        let connection = PersonalHistoryFixtures.connection(session)
        try store.save(review, connection: connection, receivedAt: instant)
        let value = try XCTUnwrap(store.read(connection: connection, now: instant))
        XCTAssertEqual(value.week?.routines, review.liveWeek)
        XCTAssertEqual(value.week?.timeZone, review.timeZone)
        XCTAssertEqual(value.week?.syncedAt, instant)
        let serialized = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        for field in ["draftWeek", "canPublish", "reviewRevision", "requestId", "deviceSecret", "Bearer"] { XCTAssertFalse(serialized.contains(field), field) }
    }

    func testDuplicateRecordingIdentityAcrossKindsCannotReplaceTheSavedCopy() throws {
        let connection = try connection(), presence = try PersonalHistoryFixtures.page()
        try store.save(presence, appending: false, connection: connection, receivedAt: instant)
        let vitals = try PersonalHistoryFixtures.changed(PersonalHistoryFixtures.page("vitalsPage")) { value in
            var records = try XCTUnwrap(value["records"] as? [[String: Any]])
            records[0]["id"] = presence.records[0].id; value["records"] = records
        }
        XCTAssertThrowsError(try store.save(vitals, appending: false, connection: connection, receivedAt: instant + 100))
        let retained = try XCTUnwrap(store.read(connection: connection, now: instant + 100))
        XCTAssertEqual(retained.recordings.count, 1)
        XCTAssertEqual(retained.recordings[0].records, presence.records)
        XCTAssertEqual(retained.recordings[0].syncedAt, instant)
    }

    func testSavedWeekKeepsItsTemperatureUnitAndRejectsUnknownUnits() throws {
        let connection = PersonalHistoryFixtures.connection(try PersonalRoutineFixtures.session())
        let review = try PersonalRoutineFixtures.review()
        try store.save(review, connection: connection, receivedAt: instant, temperatureUnit: "C")
        XCTAssertEqual(try store.read(connection: connection, now: instant)?.week?.temperatureUnit, "C")
        XCTAssertThrowsError(try store.save(review, connection: connection, receivedAt: instant + 100, temperatureUnit: "K"))
        XCTAssertEqual(try store.read(connection: connection, now: instant + 100)?.week?.syncedAt, instant)
    }

    func testLockedKeyWriteFailureKeepsEarlierEncryptedCopy() throws {
        let connection = try connection()
        try store.save(PersonalHistoryFixtures.page(), appending: false, connection: connection, receivedAt: instant)
        let blocked = PersonalOfflineLibraryStore(snapshots: .init(directory: directory, namespace: "personal-offline-test", encryptionKey: { throw HouseholdFailure.storage }))
        XCTAssertThrowsError(try blocked.save(PersonalHistoryFixtures.page("emptyPage"), appending: false, connection: connection, receivedAt: instant + 100))
        XCTAssertEqual(try store.read(connection: connection, now: instant + 100)?.recordings.first?.records.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 1)
    }

    func testReaderCanRestoreWithoutNetworkThenHidesOnInvalidationAndRemovesItsCopy() throws {
        let connection = try connection()
        try store.save(PersonalHistoryFixtures.page(), appending: false, connection: connection, receivedAt: instant)
        var permitted = true
        let reader = PersonalOfflineLibraryWorkspace(connection: connection, store: store, permitted: { permitted }, now: { self.instant })
        reader.restore(); XCTAssertEqual(reader.library?.recordings.first?.records.count, 1)
        permitted = false; reader.restore(); XCTAssertNil(reader.library)
        permitted = true; reader.restore(); reader.remove(); XCTAssertNil(reader.library)
        XCTAssertNil(try store.read(connection: connection, now: instant))
        reader.invalidate(); reader.save(try PersonalHistoryFixtures.page(), appending: false)
        XCTAssertNil(try store.read(connection: connection, now: instant))
    }

    func testOnlyValidatedCurrentHistoryRepliesEnterTheLibrary() async throws {
        let server = try PersonalHistoryTestServer(), connection = try connection()
        var accepted: [PersonalHistoryPage] = [], withdrawals = 0
        let model = PersonalHistoryWorkspace(connection: connection, client: server,
            cachePage: { page, _ in accepted.append(page) }, withdrawCache: { withdrawals += 1 }, now: { self.instant })
        await model.refresh(); XCTAssertEqual(accepted.count, 1)
        await server.hold("page")
        let reading = Task { await model.refresh() }; await server.waitHeld(); model.invalidate(); await server.release(); await reading.value
        XCTAssertEqual(accepted.count, 1); XCTAssertEqual(withdrawals, 0)
    }

    func testNetworkFailureKeepsCacheButExplicitRejectionWithdrawsIt() async throws {
        for failure: HouseholdFailure in [.uncertain, .rateLimited, .authentication, .forbidden, .conflict, .invalid] {
            let server = try PersonalHistoryTestServer(), connection = try connection()
            var withdrawals = 0
            let model = PersonalHistoryWorkspace(connection: connection, client: server, withdrawCache: { withdrawals += 1 }, now: { self.instant })
            await model.refresh(); await server.configure(sessionFailure: failure); await model.refresh()
            XCTAssertEqual(withdrawals, [.uncertain, .rateLimited].contains(failure) ? 0 : 1, String(describing: failure))
        }
    }

    func testParentRetainsReadOnlyLibraryAcrossOutageAndRelaunchWithoutGrantingControls() async throws {
        let session = try PersonalHistoryFixtures.session(), server = try ArrangementTestServer(), vault = ArrangementTestVault(session)
        await server.setSession(session)
        let record = try XCTUnwrap(vault.state.connections.first)
        let connection = PersonalBedConnection(id: record.id, endpoint: record.endpoint, token: record.deviceSecret, session: session)
        try store.save(PersonalHistoryFixtures.page(), appending: false, connection: connection, receivedAt: instant)
        await server.configure(sessionFailure: .uncertain)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let parent = HouseholdWorkspace(vault: vault, offlineStore: store, defaults: defaults, client: { _ in server }, capability: { false }, ownerEndpoint: { nil })
        parent.enter(); await parent.refresh()
        XCTAssertNil(parent.session); XCTAssertNil(parent.temperature); XCTAssertFalse(parent.maySave)
        XCTAssertEqual(parent.offlineLibrary?.library?.recordings.first?.records.count, 1)
        let reopened = HouseholdWorkspace(vault: vault, offlineStore: store, defaults: defaults, client: { _ in server }, capability: { false }, ownerEndpoint: { nil })
        reopened.enter(); await reopened.refresh()
        XCTAssertEqual(reopened.offlineLibrary?.library?.recordings.first?.records.count, 1)
        let reader = try XCTUnwrap(reopened.offlineLibrary); reopened.signOut()
        XCTAssertTrue(reader.invalidated); XCTAssertNil(reader.library); XCTAssertNil(reopened.offlineLibrary)
        let writes = await server.posts; XCTAssertTrue(writes.isEmpty)
    }

    func testRevocationAndExplicitErasureRemoveCiphertextAndPreventRelaunchRestore() async throws {
        for revoke in [true, false] {
            let session = try PersonalHistoryFixtures.session(), server = try ArrangementTestServer(), vault = ArrangementTestVault(session)
            await server.setSession(session)
            let record = try XCTUnwrap(vault.state.connections.first)
            let connection = PersonalBedConnection(id: record.id, endpoint: record.endpoint, token: record.deviceSecret, session: session)
            try store.save(PersonalHistoryFixtures.page(), appending: false, connection: connection, receivedAt: instant)
            let parent = HouseholdWorkspace(vault: vault, offlineStore: store, defaults: UserDefaults(suiteName: UUID().uuidString)!, client: { _ in server }, capability: { false }, ownerEndpoint: { nil })
            parent.enter()
            if revoke { await server.configure(sessionFailure: .authentication); await parent.refresh() }
            else { parent.erasePersonalLocalData() }
            XCTAssertTrue(vault.state.connections.isEmpty); XCTAssertNil(parent.offlineLibrary)
            XCTAssertNil(try store.read(connection: connection, now: instant))
        }
    }
}
