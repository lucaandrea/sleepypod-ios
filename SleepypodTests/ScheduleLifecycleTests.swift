import XCTest
@testable import Sleepypod

@MainActor final class ScheduleLifecycleTests: XCTestCase {
    func testOldReadCannotReplaceTheNewController() async throws {
        let original = try await MockClient().getSchedules()
        var replacement = original; replacement.left.monday.power.on = "20:15"
        let gate = ScheduleAsyncGate(original, holdRead: true)
        let model = ScheduleManager(api: ScheduleAsyncClient(gate))
        let pending = Task { await model.fetchSchedules() }; await gate.waitForRead()
        model.switchBackend(ScheduleAsyncClient(ScheduleAsyncGate(replacement))); await model.fetchSchedules()
        await gate.releaseRead(); await pending.value
        XCTAssertEqual(model.schedules?.left.monday.power.on, "20:15"); XCTAssertFalse(model.isLoading)
    }
    func testOldSaveCannotReplaceNewSchedulesOrClearTheirBusyState() async throws {
        let original = try await MockClient().getSchedules()
        let first = ScheduleAsyncGate(original, holdSave: true), second = ScheduleAsyncGate(original, holdSave: true)
        let model = ScheduleManager(api: ScheduleAsyncClient(first)); await model.fetchSchedules()
        let old = Task { await model.updateBedtime("20:15") }; await first.waitForSave()
        model.switchBackend(ScheduleAsyncClient(second)); await model.fetchSchedules()
        let next = Task { await model.updateBedtime("21:45") }; await second.waitForSave()
        await first.releaseSave(); await old.value
        XCTAssertTrue(model.isSaving); XCTAssertEqual(model.schedules?.left.monday.power.on, original.left.monday.power.on)
        await second.releaseSave(); await next.value
        XCTAssertFalse(model.isSaving); XCTAssertEqual(model.schedules?.left.monday.power.on, "21:45")
    }
    func testPendingSaveIsNotRepeatedOrReplacedByARefresh() async throws {
        let gate = ScheduleAsyncGate(try await MockClient().getSchedules(), holdSave: true)
        let model = ScheduleManager(api: ScheduleAsyncClient(gate)); await model.fetchSchedules()
        let pending = Task { await model.updateBedtime("21:45") }; await gate.waitForSave()
        await model.fetchSchedules(); await model.togglePowerSchedule()
        let counts = await gate.counts(); XCTAssertEqual(counts.reads, 1); XCTAssertEqual(counts.writes, 1)
        await gate.releaseSave(); await pending.value
        XCTAssertEqual(model.schedules?.left.monday.power.on, "21:45"); XCTAssertFalse(model.isSaving)
    }
    func testCoreSchedulePreflightCancelsWhenOwnerChangesWithoutSendingBatch() async throws {
        let keys = ["podURL", "ownerConnectionRevision"], values = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, values) { UserDefaults.standard.set(value, forKey: key) } }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ScopeScheduleProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        for change in ["endpoint", "key-revision"] {
            UserDefaults.standard.set("https://\(change).invalid", forKey: "podURL")
            let client = SleepypodCoreClient(session: session)
            let schedules = Schedules(left: CoreScheduleRows().projected, right: CoreScheduleRows().projected)
            do { _ = try await client.updateSchedules(schedules, days: [.monday]); XCTFail("An owner change must cancel the unsent batch") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        }
    }
}
private final class ScheduleAsyncClient: MockAPIClient, @unchecked Sendable {
    let gate: ScheduleAsyncGate
    init(_ gate: ScheduleAsyncGate) { self.gate = gate; super.init() }
    override func getSchedules() async throws -> Schedules { await gate.read() }
    override func updateSchedules(_ schedules: Schedules, days: Set<DayOfWeek>?) async throws -> Schedules { await gate.save(schedules) }
}
private actor ScheduleAsyncGate {
    var value: Schedules
    let holdRead: Bool
    let holdSave: Bool
    private var reads = 0, writes = 0
    private var readContinuation: CheckedContinuation<Void, Never>?, saveContinuation: CheckedContinuation<Void, Never>?
    private var readObserver: CheckedContinuation<Void, Never>?, saveObserver: CheckedContinuation<Void, Never>?
    init(_ value: Schedules, holdRead: Bool = false, holdSave: Bool = false) { self.value = value; self.holdRead = holdRead; self.holdSave = holdSave }
    func read() async -> Schedules {
        reads += 1
        if holdRead { await withCheckedContinuation { readContinuation = $0; readObserver?.resume(); readObserver = nil } }
        return value
    }
    func save(_ desired: Schedules) async -> Schedules {
        writes += 1
        if holdSave { await withCheckedContinuation { saveContinuation = $0; saveObserver?.resume(); saveObserver = nil } }
        value = desired; return value
    }
    func waitForRead() async { if readContinuation == nil { await withCheckedContinuation { readObserver = $0 } } }
    func waitForSave() async { if saveContinuation == nil { await withCheckedContinuation { saveObserver = $0 } } }
    func releaseRead() { readContinuation?.resume(); readContinuation = nil }
    func releaseSave() { saveContinuation?.resume(); saveContinuation = nil }
    func counts() -> (reads: Int, writes: Int) { (reads, writes) }
}
private final class ScopeScheduleProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.httpMethod == "GET", request.url?.path == "/api/trpc/schedules.getAll" else {
            XCTFail("Owner change must cancel every unsent mutation"); client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        if request.url?.host == "endpoint.invalid" { UserDefaults.standard.set("https://new-controller.invalid", forKey: "podURL") }
        else { UserDefaults.standard.set(UUID().uuidString, forKey: "ownerConnectionRevision") }
        let response = Data(#"{"result":{"data":{"json":{"temperature":[],"power":[],"alarm":[]}}}}"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
