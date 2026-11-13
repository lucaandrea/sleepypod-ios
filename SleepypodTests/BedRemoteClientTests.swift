import XCTest
@testable import Sleepypod

@MainActor final class BedRemoteClientTests: XCTestCase {
    func testFreshReadAllowsOneChangeThenRequiresRefresh() async {
        let transport = RemoteClientTransport(), client = transport.client()
        await client.refresh()
        XCTAssertEqual(client.snapshot?.targetF, 70)
        XCTAssertTrue(client.canAdjust(at: transport.now))
        await client.setTemperature(69)
        XCTAssertNil(client.snapshot)
        await client.setTemperature(68)
        XCTAssertEqual(transport.requests.map(\.action), [.refresh, .temperature])
        XCTAssertEqual(transport.requests.last?.temperatureF, 69)
    }

    func testUnreachableWatchDoesNotSendOrQueueAnAction() async {
        let transport = RemoteClientTransport(), client = transport.client()
        await client.refresh(); transport.reachable = false
        await client.setTemperature(69); await client.stop(vibration: true)
        XCTAssertEqual(transport.requests.map(\.action), [.refresh])
        await client.refresh()
        XCTAssertNil(client.snapshot)
        XCTAssertTrue(client.message.contains("unreachable"))
        transport.reachable = true
        await client.refresh()
        XCTAssertEqual(transport.requests.map(\.action), [.refresh, .refresh])
    }

    func testExpiredReadingsWithholdChangesButCurrentLeaseAllowsStop() async {
        let transport = RemoteClientTransport(), client = transport.client()
        await client.refresh(); transport.now.addTimeInterval(16)
        XCTAssertFalse(client.canAdjust(at: transport.now))
        XCTAssertTrue(client.canStop(at: transport.now))
        await client.setTemperature(69); await client.stop(vibration: true)
        XCTAssertEqual(transport.requests.map(\.action), [.refresh, .stopVibration])
    }

    func testExpiredLeaseWithholdsStopUntilRefresh() async {
        let transport = RemoteClientTransport(), client = transport.client()
        await client.refresh(); transport.now.addTimeInterval(31)
        await client.stop(vibration: false)
        XCTAssertEqual(transport.requests.map(\.action), [.refresh])
        await client.refresh(); await client.stop(vibration: false)
        XCTAssertEqual(transport.requests.map(\.action), [.refresh, .refresh, .stopTemperature])
    }

    func testInterruptedCommandIsUnconfirmedAndNeverReplayed() async {
        let transport = RemoteClientTransport(), client = transport.client()
        await client.refresh(); transport.failCommands = true
        await client.setTemperature(69); await client.setTemperature(69)
        XCTAssertNil(client.snapshot)
        XCTAssertTrue(client.message.contains("unconfirmed"))
        XCTAssertEqual(transport.requests.map(\.action), [.refresh, .temperature])
        transport.failCommands = false
        await client.refresh()
        XCTAssertEqual(transport.requests.map(\.action), [.refresh, .temperature, .refresh])
    }

    func testStopSupersedesWaitingAdjustmentWithoutLosingStopReply() async {
        let transport = RemoteClientTransport(), client = transport.client()
        await client.refresh(); transport.holdTemperature = true
        let adjustment = Task { await client.setTemperature(69) }
        await transport.waitHeld()
        XCTAssertTrue(client.canStop(at: transport.now))
        await client.stop(vibration: false)
        transport.release(); await adjustment.value
        XCTAssertTrue(client.message.contains("stopTemperature"))
        XCTAssertFalse(client.adjusting); XCTAssertFalse(client.stopping)
        XCTAssertEqual(transport.requests.map(\.action), [.refresh, .temperature, .stopTemperature])
    }

    func testLateReadAfterInvalidationCannotRestorePriorAccount() async {
        let transport = RemoteClientTransport(), client = transport.client()
        transport.holdRefresh = true
        let refresh = Task { await client.refresh() }
        await transport.waitHeld(); client.invalidate(); transport.release(); await refresh.value
        XCTAssertNil(client.snapshot)
        XCTAssertTrue(client.message.contains("current account"))
        XCTAssertFalse(client.refreshing)
    }

    func testWrongResponseIdentityCannotBecomeAnAvailableControl() async {
        let transport = RemoteClientTransport(), client = transport.client()
        transport.wrongIdentity = true
        await client.refresh()
        XCTAssertNil(client.snapshot)
        XCTAssertFalse(client.canAdjust(at: transport.now)); XCTAssertFalse(client.canStop(at: transport.now))
    }
}

@MainActor private final class RemoteClientTransport {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var reachable = true
    var failCommands = false
    var holdTemperature = false
    var holdRefresh = false
    var wrongIdentity = false
    var requests: [BedRemoteRequest] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func client() -> BedRemoteClient {
        .init(send: { try await self.send($0) }, reachable: { self.reachable }, now: { self.now })
    }
    func waitHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    private func send(_ data: Data) async throws -> Data {
        let request = try JSONDecoder().decode(BedRemoteRequest.self, from: data)
        requests.append(request)
        if (request.action == .temperature && holdTemperature) || (request.action == .refresh && holdRefresh) {
            await withCheckedContinuation { continuation = $0 }
        }
        if request.action != .refresh && failCommands { throw URLError(.networkConnectionLost) }
        let snapshot = request.action == .refresh ? BedRemoteSnapshot(
            lease: UUID(), receivedAt: now, expiresAt: now.addingTimeInterval(30), observationAt: now,
            person: "Example sleeper", assignment: "Right side",
            zones: [.init(id: "right", measuredF: 70, requestedF: 70, powered: true)],
            nextAlarm: "Tomorrow at 7:00", canAdjust: true, canStop: true, explanation: nil) : nil
        return try JSONEncoder().encode(BedRemoteReply(requestID: wrongIdentity ? UUID() : request.id,
            outcome: snapshot == nil ? .acknowledged : .snapshot, snapshot: snapshot, message: "Received \(request.action.rawValue)"))
    }
}
