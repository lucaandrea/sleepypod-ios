import XCTest
@testable import Sleepypod

@MainActor final class BedRemoteTests: XCTestCase {
    func testReadIsCredentialFreeAndTemperatureIsSentOnlyOnce() async throws {
        let source = RemoteBedTestSource()
        let broker = BedRemoteCoordinator(source: source, now: { source.now })
        let state = await broker.handle(.init(action: .refresh, now: source.now))
        let snapshot = try XCTUnwrap(state.snapshot)
        let wire = String(data: try JSONEncoder().encode(state), encoding: .utf8)!
        XCTAssertFalse(wire.contains("private-account-context")); XCTAssertFalse(wire.contains("token"))
        let request = BedRemoteRequest(action: .temperature, lease: snapshot.lease, temperatureF: 69, now: source.now)
        let first = await broker.handle(request), duplicate = await broker.handle(request)
        XCTAssertEqual(first, duplicate); XCTAssertEqual(first.outcome, .acknowledged)
        XCTAssertEqual(source.sent, [.temperature])
    }
    func testLostReplyCannotReplayAndFreshReadIsRequiredForAnotherTap() async throws {
        let source = RemoteBedTestSource(); source.failure = true
        let broker = BedRemoteCoordinator(source: source, now: { source.now })
        let state = await broker.handle(.init(action: .refresh, now: source.now))
        let request = BedRemoteRequest(action: .temperature, lease: try XCTUnwrap(state.snapshot).lease, temperatureF: 69, now: source.now)
        let result = await broker.handle(request), duplicate = await broker.handle(request)
        XCTAssertEqual(result.outcome, .uncertain); XCTAssertEqual(duplicate, result)
        var again = request; again.id = UUID()
        let second = await broker.handle(again)
        XCTAssertEqual(second.outcome, .withheld); XCTAssertEqual(source.sent.count, 1)
    }
    func testAccountSwitchHidesPriorReceiptAndRefusesOldLease() async throws {
        let source = RemoteBedTestSource()
        let controller = BedRemoteCoordinator(source: source, now: { source.now })
        let read = await controller.handle(.init(action: .refresh, now: source.now))
        let request = BedRemoteRequest(action: .stopTemperature, lease: try XCTUnwrap(read.snapshot).lease, now: source.now)
        _ = await controller.handle(request)
        source.context = ["another-person"]
        let result = await controller.handle(request)
        XCTAssertEqual(result.outcome, .withheld); XCTAssertEqual(source.sent.count, 1)
    }
    func testStaleReadingsWithholdTemperatureButAllowExplicitStop() async throws {
        let source = RemoteBedTestSource(); source.stale = true
        let broker = BedRemoteCoordinator(source: source, now: { source.now })
        let read = await broker.handle(.init(action: .refresh, now: source.now))
        let lease = try XCTUnwrap(read.snapshot).lease
        let temperature = await broker.handle(.init(action: .temperature, lease: lease, temperatureF: 69, now: source.now))
        let stop = await broker.handle(.init(action: .stopTemperature, lease: lease, now: source.now))
        XCTAssertEqual(temperature.outcome, .withheld); XCTAssertEqual(stop.outcome, .acknowledged)
        XCTAssertEqual(source.sent, [.stopTemperature])
    }
    func testPhoneRestartCannotUsePriorWatchLease() async throws {
        let source = RemoteBedTestSource()
        let original = BedRemoteCoordinator(source: source, now: { source.now })
        let read = await original.handle(.init(action: .refresh, now: source.now))
        let restarted = BedRemoteCoordinator(source: source, now: { source.now })
        let result = await restarted.handle(.init(action: .stopTemperature, lease: try XCTUnwrap(read.snapshot).lease, now: source.now))
        XCTAssertEqual(result.outcome, .withheld); XCTAssertTrue(source.sent.isEmpty)
    }
    func testStopCancelsAdjustmentWaitingForFreshPreflight() async throws {
        let source = RemoteBedTestSource(); source.holdTemperature = true
        let broker = BedRemoteCoordinator(source: source, now: { source.now })
        let read = await broker.handle(.init(action: .refresh, now: source.now)), lease = try XCTUnwrap(read.snapshot).lease
        let task = Task { await broker.handle(.init(action: .temperature, lease: lease, temperatureF: 69, now: source.now)) }
        await source.waitForHold()
        let stop = await broker.handle(.init(action: .stopTemperature, lease: lease, now: source.now))
        source.release()
        let adjustment = await task.value
        XCTAssertEqual(stop.outcome, .acknowledged); XCTAssertEqual(adjustment.outcome, .uncertain)
        XCTAssertEqual(source.sent, [.stopTemperature])
    }
    func testExpiredDuringPreflightDoesNotDispatch() async throws {
        let source = RemoteBedTestSource(); source.holdTemperature = true
        let broker = BedRemoteCoordinator(source: source, now: { source.now })
        let read = await broker.handle(.init(action: .refresh, now: source.now)), lease = try XCTUnwrap(read.snapshot).lease
        let task = Task { await broker.handle(.init(action: .temperature, lease: lease, temperatureF: 69, now: source.now)) }
        await source.waitForHold(); source.now.addTimeInterval(16); source.release()
        _ = await task.value
        XCTAssertTrue(source.sent.isEmpty)
    }
    func testDuplicateDuringDispatchAndConflictingIDNeverSendAgain() async throws {
        let source = RemoteBedTestSource(); source.holdTemperature = true
        let broker = BedRemoteCoordinator(source: source, now: { source.now })
        let read = await broker.handle(.init(action: .refresh, now: source.now))
        let request = BedRemoteRequest(action: .temperature, lease: try XCTUnwrap(read.snapshot).lease, temperatureF: 69, now: source.now)
        let task = Task { await broker.handle(request) }; await source.waitForHold()
        let duplicate = await broker.handle(request)
        var conflict = request; conflict.temperatureF = 80
        let altered = await broker.handle(conflict)
        XCTAssertEqual(duplicate.outcome, .uncertain); XCTAssertEqual(altered.outcome, .withheld)
        source.release(); _ = await task.value
        XCTAssertEqual(source.sent, [.temperature])
    }
    func testFutureExpiredMalformedAndWrongLeaseRequestsCannotDispatch() async throws {
        let source = RemoteBedTestSource()
        let controller = BedRemoteCoordinator(source: source, now: { source.now })
        let read = await controller.handle(.init(action: .refresh, now: source.now))
        let valid = BedRemoteRequest(action: .temperature, lease: try XCTUnwrap(read.snapshot).lease, temperatureF: 69, now: source.now)
        var invalid: [BedRemoteRequest] = []
        var value = valid; value.issuedAt = source.now.addingTimeInterval(1); invalid.append(value)
        value = valid; value.expiresAt = source.now; invalid.append(value)
        value = valid; value.temperatureF = 111; invalid.append(value)
        value = valid; value.lease = UUID(); invalid.append(value)
        value = valid; value.version = 2; invalid.append(value)
        value = valid; value.expiresAt = source.now.addingTimeInterval(31); invalid.append(value)
        for request in invalid { let result = await controller.handle(request); XCTAssertEqual(result.outcome, .withheld) }
        XCTAssertTrue(source.sent.isEmpty)
    }
}

@MainActor private final class RemoteBedTestSource: BedRemoteSource {
    var context = ["private-account-context"]
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var stale = false
    var failure = false
    var holdTemperature = false
    var sent: [BedRemoteRequest.Action] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func waitForHold() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    func read() async throws -> BedRemoteReading {
        .init(context: context, snapshot: .init(lease: UUID(), receivedAt: now, expiresAt: now.addingTimeInterval(30),
            observationAt: now.addingTimeInterval(stale ? -60 : -1), person: "Example sleeper", assignment: "Right side",
            zones: [.init(id: "right", measuredF: 70, requestedF: 70, powered: true)], nextAlarm: "Tomorrow at 7:00 AM",
            canAdjust: !stale, canStop: true, explanation: nil))
    }
    func perform(_ request: BedRemoteRequest, reviewed: BedRemoteReading,
                 validateBeforeSubmit: @escaping @MainActor () throws -> Void) async throws -> String {
        if request.action == .temperature, holdTemperature { await withCheckedContinuation { continuation = $0 } }
        try validateBeforeSubmit()
        sent.append(request.action)
        if failure { throw URLError(.networkConnectionLost) }
        return "Controller acknowledged. Physical response is unverified."
    }
}
