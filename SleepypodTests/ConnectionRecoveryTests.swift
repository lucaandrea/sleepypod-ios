import XCTest
@testable import Sleepypod

@MainActor final class ConnectionRecoveryTests: XCTestCase {
    func testBriefOutageRetainsRecentStatusButStaleStatusDisconnectsAndRecovers() async throws {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        let client = RecoveryClient(status: try await MockClient().getDeviceStatus())
        let manager = DeviceManager(api: client, now: { now })
        await manager.fetchStatus()
        XCTAssertTrue(manager.isConnected)
        await client.gate.setFailure(true)
        now = now.addingTimeInterval(10)
        await manager.fetchStatus()
        XCTAssertTrue(manager.isConnected)
        now = now.addingTimeInterval(21)
        await manager.fetchStatus()
        XCTAssertFalse(manager.isConnected)
        XCTAssertNotNil(manager.deviceStatus)
        await client.gate.setFailure(false)
        await manager.fetchStatus()
        XCTAssertTrue(manager.isConnected)
        XCTAssertEqual(manager.lastUpdated, now)
        XCTAssertNil(manager.error)
    }
    func testForegroundResumeReadsImmediatelyInsteadOfWaitingForPollingInterval() async throws {
        let client = RecoveryClient(status: try await MockClient().getDeviceStatus())
        let manager = DeviceManager(api: client)
        await manager.fetchStatus()
        manager.suspendConnection()
        manager.resumeConnection()
        defer { manager.stopPolling() }
        for _ in 0..<100 where await client.gate.count < 2 { await Task.yield() }
        let count = await client.gate.count
        XCTAssertEqual(count, 2)
    }
}

private final class RecoveryClient: MockAPIClient, @unchecked Sendable {
    let gate: RecoveryGate
    init(status: DeviceStatus) { gate = RecoveryGate(status: status) }
    override func getDeviceStatus() async throws -> DeviceStatus { try await gate.read() }
}
private actor RecoveryGate {
    let status: DeviceStatus
    var failure = false
    private(set) var count = 0
    init(status: DeviceStatus) { self.status = status }
    func setFailure(_ value: Bool) { failure = value }
    func read() throws -> DeviceStatus {
        count += 1
        if failure { throw APIError.noBaseURL }
        return status
    }
}
