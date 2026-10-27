import XCTest
@testable import Sleepypod

@MainActor final class StatusLifecycleTests: XCTestCase {
    func testEveryCountedServiceIsInspectableAndFailuresAreNamed() async throws {
        var status = try await MockClient().getServerStatus()
        status.analyzeSleepLeft = .init(name: "Left sleep analysis", status: .failed, description: "Analysis worker", message: "Worker stopped")
        status.biometricsCalibrationRight = .init(name: "Right calibration", status: .notStarted, description: "Calibration", message: "No baseline")
        let manager = StatusManager(api: MockAPIClient()); manager.serverStatus = status
        let visible = manager.categories().flatMap(\.services)
        XCTAssertEqual(visible.count, manager.totalCount)
        XCTAssertEqual(Set(visible.map(\.name)), Set(status.allStatuses.map(\.name)))
        XCTAssertEqual(visible.filter(\.status.isHealthy).count, manager.healthyCount)
        XCTAssertTrue(manager.servicesNeedingAttention.contains { $0.name == "Left sleep analysis" && $0.message == "Worker stopped" })
        XCTAssertTrue(manager.servicesNeedingAttention.contains { $0.name == "Right calibration" && $0.status == .notStarted })
        XCTAssertFalse(manager.servicesNeedingAttention.contains { $0.status.isHealthy })
    }

    func testFailedRefreshRetainsLastSuccessfulReceiptAndMarksStatusStale() async throws {
        let client = LifecycleStatusClient(status: try await MockClient().getServerStatus())
        let model = StatusManager(api: client)
        XCTAssertFalse(model.internetIsFresh())
        await model.fetchAll()
        let receipt = try XCTUnwrap(model.lastUpdated)
        XCTAssertTrue(model.statusIsFresh(now: receipt.addingTimeInterval(30)))
        XCTAssertFalse(model.statusIsFresh(now: receipt.addingTimeInterval(31)))
        XCTAssertTrue(model.internetIsFresh())
        await client.statusGate.fail()
        await client.internetGate.fail()
        await model.fetchAll()
        XCTAssertEqual(model.lastUpdated, receipt)
        XCTAssertNotNil(model.serverStatus)
        XCTAssertFalse(model.statusIsFresh())
        XCTAssertFalse(model.internetIsFresh())
    }
    func testResponsesFromPreviousControllerCannotRepopulateResetState() async throws {
        let old = LifecycleStatusClient(status: try await MockClient().getServerStatus(), paused: true)
        let model = StatusManager(api: old)
        let pending = Task { await model.fetchAll() }
        await old.statusGate.waitForRead(); await old.internetGate.waitForRead()
        model.switchBackend(MockAPIClient())
        XCTAssertNil(model.serverStatus)
        XCTAssertFalse(model.isLoading)
        await old.statusGate.release(); await old.internetGate.release()
        await pending.value
        XCTAssertNil(model.serverStatus)
        XCTAssertNil(model.lastUpdated)
        XCTAssertNil(model.internetUpdatedAt)
        XCTAssertFalse(model.isInternetBlocked)
    }
    func testInternetReadStartedBeforeToggleCannotUndoAcknowledgedChange() async throws {
        let client = LifecycleStatusClient(status: try await MockClient().getServerStatus(), paused: true)
        let model = StatusManager(api: client)
        let pending = Task { await model.fetchAll() }
        await client.internetGate.waitForRead()
        await model.setInternetAccess(blocked: true)
        await client.internetGate.release(); await client.statusGate.release()
        await pending.value
        XCTAssertTrue(model.isInternetBlocked)
        XCTAssertTrue(model.internetIsFresh())
    }
    func testCancelledReadDoesNotAdvanceReceiptOrShowAnError() async throws {
        let client = LifecycleStatusClient(status: try await MockClient().getServerStatus(), paused: true)
        let model = StatusManager(api: client)
        let pending = Task { await model.fetchAll() }
        await client.statusGate.waitForRead()
        pending.cancel()
        await client.statusGate.release(); await client.internetGate.release()
        await pending.value
        XCTAssertNil(model.lastUpdated)
        XCTAssertNil(model.serverStatus)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isLoading)
    }
    func testOverlappingRefreshesShareTheExistingInFlightRead() async throws {
        let client = LifecycleStatusClient(status: try await MockClient().getServerStatus(), paused: true)
        let model = StatusManager(api: client)
        let pending = Task { await model.fetchAll() }
        await client.statusGate.waitForRead()
        await model.fetchAll()
        let count = await client.statusGate.readCount
        XCTAssertEqual(count, 1)
        await client.statusGate.release(); await client.internetGate.release()
        await pending.value
        XCTAssertFalse(model.isLoading)
    }
}
private final class LifecycleStatusClient: MockAPIClient, @unchecked Sendable {
    let statusGate: LifecycleReadGate<ServerStatus>
    let internetGate: LifecycleReadGate<Bool>
    init(status: ServerStatus, paused: Bool = false) {
        statusGate = .init(value: status, paused: paused)
        internetGate = .init(value: false, paused: paused)
    }
    override func getServerStatus() async throws -> ServerStatus { try await statusGate.read() }
    override func getInternetStatus() async throws -> Bool { try await internetGate.read() }
    override func getServices() async throws -> Services { try await MockClient().getServices() }
}
private actor LifecycleReadGate<Value: Sendable> {
    private let value: Value
    private var paused: Bool
    private var fails = false
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var readCount = 0
    init(value: Value, paused: Bool) { self.value = value; self.paused = paused }
    func read() async throws -> Value {
        readCount += 1; started?.resume(); started = nil
        if paused { await withCheckedContinuation { pending = $0 } }
        if fails { throw APIError.noBaseURL }
        return value
    }
    func waitForRead() async {
        if readCount == 0 { await withCheckedContinuation { started = $0 } }
    }
    func release() { paused = false; pending?.resume(); pending = nil }
    func fail() { fails = true }
}
