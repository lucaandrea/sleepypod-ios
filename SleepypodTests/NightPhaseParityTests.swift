import XCTest
@testable import Sleepypod

@MainActor final class NightPhaseParityTests: XCTestCase {
    private let timezone = "America/Los_Angeles"
    private var now: Date { ISO8601DateFormatter().date(from: "2026-10-25T09:00:00Z")! }
    private func fixture() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "temperature-core", withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func rows() throws -> CoreScheduleRows {
        let night = try XCTUnwrap(fixture()["night"] as? [String: Any])
        let temperatures = try XCTUnwrap(night["temperatures"] as? [[String: Any]]).map { $0.merging(["side": "left"]) { _, new in new } }
        let power = try XCTUnwrap(night["power"] as? [[String: Any]]).map { $0.merging(["side": "left", "onTime": "22:00", "offTime": "07:00", "onTemperature": 74, "enabled": true]) { _, new in new } }
        return try JSONDecoder().decode(CoreScheduleRows.self, from: JSONSerialization.data(withJSONObject: ["temperature": temperatures, "power": power, "alarm": []]))
    }
    func testPhaseGroupingAndShiftMatchLiteralWebFixture() throws {
        let night = try XCTUnwrap(fixture()["night"] as? [String: Any])
        let expected = try XCTUnwrap(night["phases"] as? [String: Any]).merging(["draft": false]) { _, new in new }
        let phases = try JSONDecoder().decode(NightPhases.self, from: JSONSerialization.data(withJSONObject: expected))
        let rows = try rows(), snapshot = try NightPhaseSnapshot.make(side: .left, rows: rows, now: now, timezone: timezone)
        XCTAssertEqual(snapshot.phases, phases)
        XCTAssertEqual(Set(phases.days), [.saturday, .sunday])
        let batch = try snapshot.batch(latest: rows, targets: [.night: Int(floor(phases.night.temperatureF + 0.5)) + 3], now: now, timezone: timezone, endAction: .turnOff)
        let updates = try JSONSerialization.jsonObject(with: JSONEncoder().encode(batch.updates.temperature)) as? NSArray
        XCTAssertEqual(updates, night["updates"] as? NSArray)
        XCTAssertTrue(batch.deletes.alarm.isEmpty); XCTAssertTrue(batch.creates.alarm.isEmpty); XCTAssertTrue(batch.updates.power.isEmpty)
    }
    func testTemplateBatchMatchesWebAndPreservesAlarmRows() throws {
        let fixture = try fixture(), template = try XCTUnwrap(fixture["template"] as? [String: Any])
        let rows = try rows(), date = ISO8601DateFormatter().date(from: "2026-10-28T04:00:00Z")!
        let snapshot = try NightPhaseSnapshot.make(side: .left, rows: rows, now: date, timezone: timezone)
        XCTAssertTrue(snapshot.phases.draft); XCTAssertEqual(Set(snapshot.phases.days), [.tuesday, .wednesday, .thursday, .friday])
        let batch = try snapshot.batch(latest: rows, targets: [.night: 75, .dawn: 80], now: date, timezone: timezone, endAction: .maintain)
        var actual = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as? [String: Any])
        actual.removeValue(forKey: "updates")
        XCTAssertEqual(actual as NSDictionary, template["batch"] as? NSDictionary)
        XCTAssertFalse(batch.matches(rows, side: .left))
    }
    func testPodTimezoneAndFourAMBoundaryIgnorePhoneClock() {
        XCTAssertEqual(NightPhaseProjection.currentDay(now: now, timezone: timezone), .saturday)
        XCTAssertEqual(NightPhaseProjection.currentDay(now: now.addingTimeInterval(7200), timezone: timezone), .sunday)
        XCTAssertEqual(NightPhaseProjection.currentDay(now: now, timezone: "Asia/Tokyo"), .sunday)
    }
    func testChangedScheduleOrOwningDayBlocksWriteButAlarmChangesDoNot() throws {
        let rows = try rows(), snapshot = try NightPhaseSnapshot.make(side: .left, rows: rows, now: now, timezone: timezone)
        var changed = rows; changed.temperature[0].temperature = 80
        XCTAssertThrowsError(try snapshot.batch(latest: changed, targets: [.night: 74], now: now, timezone: timezone, endAction: .turnOff))
        XCTAssertThrowsError(try snapshot.batch(latest: rows, targets: [.night: 74], now: now.addingTimeInterval(7200), timezone: timezone, endAction: .turnOff))
        var alarm = AlarmDraft(sides: [.left]); alarm.days = [.saturday]
        changed = rows; changed.alarm = alarm.creates.map { $0.row(id: 200) }
        XCTAssertNoThrow(try snapshot.batch(latest: changed, targets: [.night: 74], now: now, timezone: timezone, endAction: .turnOff))
    }
    func testSinglePointHasNoDawnAndWrongSideDataIsRejected() throws {
        var rows = try rows(); rows.temperature = [rows.temperature[0]]
        XCTAssertNil(try NightPhaseSnapshot.make(side: .left, rows: rows, now: now, timezone: timezone).phases.dawn)
        XCTAssertThrowsError(try NightPhaseSnapshot.make(side: .right, rows: rows, now: now, timezone: timezone))
    }
    func testBothPhaseNudgesUseOneWriteAndReadBack() async throws {
        let client = NightPhaseRecordingClient(rows: try rows()), store = NightPhasesStore(), now = now
        store.configure(client: client, timezone: timezone, clock: { now }, delay: .milliseconds(50))
        await store.load([.left])
        store.nudge([.left], phase: .night, delta: 1, format: .fahrenheit)
        store.nudge([.left], phase: .dawn, delta: 1, format: .fahrenheit)
        await settle { await client.writeCount == 1 && store.canEdit(.left) }
        XCTAssertNil(store.error); XCTAssertEqual(store.value(.left, .night), 71); XCTAssertEqual(store.value(.left, .dawn), 83)
        let writes = await client.writeCount; XCTAssertEqual(writes, 1)
    }
    func testUnknownWriteKeepsDraftBlocksRetryAndAllowsExplicitReadback() async throws {
        let client = NightPhaseRecordingClient(rows: try rows()), store = NightPhasesStore(), now = now
        await client.setAmbiguous()
        store.configure(client: client, timezone: timezone, clock: { now }, delay: .milliseconds(1)); await store.load([.left])
        store.nudge([.left], phase: .night, delta: 1, format: .fahrenheit)
        await settle { store.error != nil }
        XCTAssertFalse(store.canEdit(.left)); XCTAssertEqual(store.value(.left, .night), 71)
        store.nudge([.left], phase: .night, delta: 1, format: .fahrenheit)
        try await Task.sleep(for: .milliseconds(25))
        var count = await client.writeCount; XCTAssertEqual(count, 1)
        await store.load([.left]); XCTAssertTrue(store.canEdit(.left)); XCTAssertNil(store.error)
        XCTAssertEqual(store.value(.left, .night), 71); count = await client.writeCount; XCTAssertEqual(count, 1)
    }
    func testOwnerChangeCancelsUnsentNudgesAndDoesNotRetarget() async throws {
        let first = NightPhaseRecordingClient(rows: try rows()), second = NightPhaseRecordingClient(rows: try rows()), store = NightPhasesStore(), now = now
        store.configure(client: first, timezone: timezone, clock: { now }, delay: .milliseconds(40)); await store.load([.left])
        store.nudge([.left], phase: .night, delta: 1, format: .fahrenheit)
        store.configure(client: second, timezone: timezone, clock: { now }); await store.load([.left])
        try await Task.sleep(for: .milliseconds(80))
        let oldCount = await first.writeCount, newCount = await second.writeCount
        XCTAssertEqual(oldCount, 0); XCTAssertEqual(newCount, 0); XCTAssertEqual(store.value(.left, .night), 70)
    }
    func testOneSideFailureDoesNotDisappearWhenOtherSideLoads() async throws {
        let client = NightPhaseRecordingClient(rows: try rows()), store = NightPhasesStore(), now = now
        await client.failLeft()
        store.configure(client: client, timezone: timezone, clock: { now }); await store.load([.left, .right])
        XCTAssertNotNil(store.errors[.left]); XCTAssertNotNil(store.phases[.right]); XCTAssertFalse(store.canEdit(.left))
    }
    func testSuccessfulResponseWithoutChangedReadbackDoesNotClaimSaved() async throws {
        let client = NightPhaseRecordingClient(rows: try rows()), store = NightPhasesStore(), now = now
        await client.ignoreWrites()
        store.configure(client: client, timezone: timezone, clock: { now }, delay: .milliseconds(1)); await store.load([.left])
        store.nudge([.left], phase: .night, delta: 1, format: .fahrenheit)
        await settle { store.error != nil }
        XCTAssertTrue(store.saved.isEmpty); XCTAssertFalse(store.canEdit(.left)); XCTAssertTrue(store.error?.contains("did not match") == true)
    }
    func testOwnerChangeDuringReadBeforeWriteDiscardsTheUnsentBatch() async throws {
        let first = NightPhaseRecordingClient(rows: try rows()), second = NightPhaseRecordingClient(rows: try rows()), store = NightPhasesStore(), now = now
        store.configure(client: first, timezone: timezone, clock: { now }, delay: .milliseconds(1)); await store.load([.left])
        await first.holdNextRead()
        store.nudge([.left], phase: .night, delta: 1, format: .fahrenheit)
        await settle { await first.waiting }
        store.configure(client: second, timezone: timezone, clock: { now }); await store.load([.left])
        await first.releaseRead(); try await Task.sleep(for: .milliseconds(20))
        let oldCount = await first.writeCount, newCount = await second.writeCount
        XCTAssertEqual(oldCount, 0); XCTAssertEqual(newCount, 0); XCTAssertEqual(store.value(.left, .night), 70)
    }
    func testDemoUsesDistinctSidesAndPublishesSavedSchedule() async throws {
        let api = MockClient(), client = DemoNightPhaseClient(api: api)
        let left = try await client.rows(side: .left), right = try await client.rows(side: .right)
        XCTAssertTrue(Set(left.temperature.map(\.id)).isDisjoint(with: right.temperature.map(\.id)))
        let snapshot = try NightPhaseSnapshot.make(side: .left, rows: left, now: now, timezone: timezone)
        let desired = Int(floor(snapshot.phases.night.temperatureF + 0.5)) + 2
        let batch = try snapshot.batch(latest: left, targets: [.night: desired], now: now, timezone: timezone, endAction: .turnOff)
        try await client.apply(batch)
        let savedLeft = try await client.rows(side: .left), savedRight = try await client.rows(side: .right)
        XCTAssertTrue(batch.matches(savedLeft, side: .left)); XCTAssertEqual(savedRight, right)
        let shared = try await api.getSchedules()
        XCTAssertEqual(shared.left.saturday.temperatures, savedLeft.projected.saturday.temperatures)
        XCTAssertEqual(shared.right.saturday.temperatures, right.projected.saturday.temperatures)
    }
    private func settle(_ condition: () async -> Bool) async {
        for _ in 0..<100 { if await condition() { return }; try? await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out waiting for a bounded mock schedule operation")
    }
}
private actor NightPhaseRecordingClient: NightPhaseClient {
    private var stored: CoreScheduleRows
    private var ambiguous = false, leftFailure = false, ignore = false, hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    private(set) var writeCount = 0
    init(rows: CoreScheduleRows) { stored = rows }
    func setAmbiguous() { ambiguous = true }
    func failLeft() { leftFailure = true }
    func ignoreWrites() { ignore = true }
    func holdNextRead() { hold = true }
    func releaseRead() { continuation?.resume(); continuation = nil }
    func rows(side: Side) async throws -> CoreScheduleRows {
        if hold { hold = false; await withCheckedContinuation { continuation = $0 } }
        if side == .left && leftFailure { throw URLError(.notConnectedToInternet) }
        var rows = stored
        for index in rows.temperature.indices { rows.temperature[index].side = side.rawValue }
        for index in rows.power.indices { rows.power[index].side = side.rawValue }
        return rows
    }
    func apply(_ batch: NightPhaseBatch) throws {
        writeCount += 1
        if ignore { return }
        for update in batch.updates.temperature {
            if let index = stored.temperature.firstIndex(where: { $0.id == update.id }) { stored.temperature[index].temperature = update.temperature }
        }
        if ambiguous { throw URLError(.networkConnectionLost) }
    }
}
