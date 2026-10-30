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
    func testRetryAndRouteRecoveryReadStatusWithoutReplayingCommands() async throws {
        let client = RecoveryClient(status: try await MockClient().getDeviceStatus())
        let manager = DeviceManager(api: client)
        await client.gate.setFailure(true)
        await manager.fetchStatus()
        XCTAssertEqual(manager.connectionIssue, .unconfigured)
        await client.gate.setFailure(false)
        manager.networkRouteChanged()
        defer { manager.stopPolling() }
        for _ in 0..<100 where !manager.isConnected { await Task.yield() }
        XCTAssertTrue(manager.isConnected)
        XCTAssertNil(manager.connectionIssue)
        let before = await client.gate.count
        manager.networkRouteChanged()
        for _ in 0..<10 { await Task.yield() }
        let after = await client.gate.count
        XCTAssertEqual(before, after, "A healthy connection should not be reset by route notifications")
        let writes = await client.gate.writes
        XCTAssertEqual(writes, 0)
    }

}

private final class RecoveryClient: MockAPIClient, @unchecked Sendable {
    let gate: RecoveryGate
    init(status: DeviceStatus) { gate = RecoveryGate(status: status) }
    override func getDeviceStatus() async throws -> DeviceStatus { try await gate.read() }
    override func updateDeviceStatus(_ update: DeviceStatusUpdate) async throws { await gate.wrote() }
}
private actor RecoveryGate {
    let status: DeviceStatus
    var failure = false
    private(set) var count = 0
    private(set) var writes = 0
    func wrote() { writes += 1 }
    init(status: DeviceStatus) { self.status = status }
    func setFailure(_ value: Bool) { failure = value }
    func read() throws -> DeviceStatus {
        count += 1
        if failure { throw APIError.noBaseURL }
        return status
    }
}
