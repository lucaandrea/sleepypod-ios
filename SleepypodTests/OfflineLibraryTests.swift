import CryptoKit
import FreeSleepKit
import XCTest
@testable import Sleepypod

@MainActor final class OfflineLibraryTests: XCTestCase {
    private var directory: URL!
    private var store: PrivateSnapshotStore!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let key = SymmetricKey(size: .bits256)
        store = .init(directory: directory, namespace: "test", encryptionKey: { key })
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    func testRefreshSurvivesRelaunchWithoutAnyWritesAndKeepsSidesSeparate() async throws {
        let now = Date()
        let client = OfflineReadClient(schedules: try await MockClient().getSchedules(), now: now)
        let session = OfflineLibrarySession(store: store, currentScope: { "luca-pod" }, now: { now })
        await session.refresh(client: client, timeZone: "Europe/Rome")
        XCTAssertNotNil(session.library.schedules)
        XCTAssertEqual(session.library.left?.value.map(\.side), ["left"])
        XCTAssertEqual(session.library.right?.value.map(\.side), ["right"])
        XCTAssertEqual(client.writes, 0)
        let restored = OfflineLibrarySession(store: store, currentScope: { "luca-pod" })
        restored.restore()
        XCTAssertEqual(restored.library.left?.savedAt, now)
        XCTAssertEqual(restored.library.timeZone, "Europe/Rome")
        XCTAssertEqual(restored.library.left?.value, session.library.left?.value)
    }

    func testPartialFailureRetainsPriorTimestampRatherThanClaimingNewSync() async throws {
        var now = Date()
        let client = OfflineReadClient(schedules: try await MockClient().getSchedules(), now: now)
        let session = OfflineLibrarySession(store: store, currentScope: { "pod" }, now: { now })
        await session.refresh(client: client, timeZone: "UTC")
        let previous = try XCTUnwrap(session.library.left?.savedAt)
        now = now.addingTimeInterval(120)
        client.leftFailure = URLError(.notConnectedToInternet)
        await session.refresh(client: client, timeZone: "UTC")
        XCTAssertEqual(session.library.left?.savedAt, previous)
        XCTAssertEqual(session.library.schedules?.savedAt, now)
        XCTAssertNotNil(session.error)
        XCTAssertEqual(client.writes, 0)
    }

    func testChangingAccountOrWithdrawingClearsVisibleData() async throws {
        var scope: String? = "luca"
        let session = OfflineLibrarySession(store: store, currentScope: { scope })
        let client = OfflineReadClient(schedules: try await MockClient().getSchedules(), now: Date())
        await session.refresh(client: client, timeZone: "UTC")
        scope = "marissa"
        XCTAssertNil(session.library.schedules, "Account changes withdraw visible data before asynchronous view tasks run")
        session.restore()
        XCTAssertNil(session.library.left)
        XCTAssertNil(session.library.schedules)
        scope = "luca"; session.restore()
        XCTAssertNotNil(session.library.schedules)
        session.withdraw()
        XCTAssertNil(session.library.schedules)
        scope = nil; session.restore()
        XCTAssertNil(session.library.left)
    }

    func testLateResponseCannotPopulateNewAccountOrWriteItsCache() async throws {
        var scope: String? = "luca"
        let session = OfflineLibrarySession(store: store, currentScope: { scope })
        let client = OfflineReadClient(schedules: try await MockClient().getSchedules(), now: Date())
        client.beforeSchedule = { scope = "marissa"; session.restore() }
        await session.refresh(client: client, timeZone: "UTC")
        XCTAssertNil(session.library.schedules)
        XCTAssertNil(try store.read(OfflineLibrary.self, scope: "luca"))
        XCTAssertNil(try store.read(OfflineLibrary.self, scope: "marissa"))
    }

    func testAuthenticationRejectionErasesSavedControllerData() async throws {
        let client = OfflineReadClient(schedules: try await MockClient().getSchedules(), now: Date())
        let session = OfflineLibrarySession(store: store, currentScope: { "pod" })
        await session.refresh(client: client, timeZone: "UTC")
        client.leftFailure = APIError.invalidResponse(statusCode: 403)
        await session.refresh(client: client, timeZone: "UTC")
        XCTAssertNil(session.library.schedules)
        XCTAssertNil(try store.read(OfflineLibrary.self, scope: "pod"))
        XCTAssertEqual(client.writes, 0)
    }
}

private final class OfflineReadClient: MockAPIClient, @unchecked Sendable {
    let schedules: Schedules
    let now: Date
    var leftFailure: Error?
    var writes = 0
    var beforeSchedule: (@MainActor () -> Void)?
    init(schedules: Schedules, now: Date) { self.schedules = schedules; self.now = now }
    override func getSchedules() async throws -> Schedules { await beforeSchedule?(); return schedules }
    override func getSleepRecords(side: Side?, start: Date?, end: Date?) async throws -> [SleepRecord] {
        if side == .left, let leftFailure { throw leftFailure }
        return [SleepRecord(id: 1, side: "left", enteredBed: now.addingTimeInterval(-8 * 3600), leftBed: now),
                SleepRecord(id: 2, side: "right", enteredBed: now.addingTimeInterval(-7 * 3600), leftBed: now),
                SleepRecord(id: 3, side: "left", enteredBed: now.addingTimeInterval(-60 * 86400), leftBed: now),
                SleepRecord(id: 4, side: "left", enteredBed: now.addingTimeInterval(1000), leftBed: nil)]
    }
    override func updateDeviceStatus(_ update: DeviceStatusUpdate) async throws { writes += 1 }
    override func updateSchedules(_ schedules: Schedules, days: Set<DayOfWeek>? = nil) async throws -> Schedules { writes += 1; return schedules }
}
