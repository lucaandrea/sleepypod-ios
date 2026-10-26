import Foundation
import XCTest
@testable import Sleepypod

@MainActor
final class AlarmParityTests: XCTestCase {
    private func row(_ id: Int = 1, day: DayOfWeek = .monday, enabled: Bool = true, window: Int = 20) -> CoreAlarmRow {
        CoreAlarmRow(id: id, side: .left, dayOfWeek: day, time: "07:00", vibrationIntensity: 40, vibrationPattern: .double,
                     duration: 20, alarmTemperature: 84, enabled: enabled, wakeWindow: window, snoozeDuration: 540, snoozeTaper: 30)
    }
    func testTemperatureContextUsesOnlyActiveSleeperWithoutChangingThermalSides() async throws {
        var settings = try await MockClient().getSettings()
        XCTAssertEqual(settings.contextSide(selected: .left), .left)
        XCTAssertEqual(settings.contextSide(selected: .right), .right)
        settings.left.awayMode = true
        XCTAssertEqual(settings.contextSide(selected: .left), .right)
        settings.right.awayMode = true
        XCTAssertEqual(settings.contextSide(selected: .left), .left, "No active sleeper falls back to the selected side")
        settings.left.awayMode = false; settings.right.awayMode = false; settings.bedMode = "solo-right"
        XCTAssertEqual(settings.contextSide(selected: .left), .right)
        settings.right.awayMode = true
        XCTAssertEqual(settings.contextSide(selected: .left), .left)
        XCTAssertEqual(Side.allCases.count, 2, "Thermal zone selection is independent of context visibility")
    }
    func testStaleAlarmsStopNextOccurrenceAndMutationsUntilFreshRead() async throws {
        let client = AlarmRecordingClient(rows: [row()]); let model = AlarmWorkspace(api: client)
        await model.refresh(); let group = try XCTUnwrap(model.groups(.left).first)
        await client.fail(true); await model.refresh()
        XCTAssertFalse(model.loaded); XCTAssertEqual(model.rows, [row()])
        XCTAssertEqual(model.error, "The controller connection is offline. Check your network and reload.")
        XCTAssertNil(model.nextGroup(.left, now: .now, timeZone: .gmt))
        await model.toggle(group, enabled: false); await model.test(AlarmDraft(group: group))
        let writes = await client.writes; let tests = await client.tests
        XCTAssertTrue(writes.isEmpty); XCTAssertTrue(tests.isEmpty)
        await client.fail(false); await model.refresh()
        XCTAssertTrue(model.loaded); XCTAssertNil(model.error)
        await model.toggle(group, enabled: false)
        XCTAssertEqual(model.rows.first?.enabled, false)
    }
    func testUnknownAlarmWriteNeedsReadBeforeManualResubmission() async throws {
        let client = AlarmRecordingClient(rows: [row()]); let model = AlarmWorkspace(api: client)
        await model.refresh(); let group = try XCTUnwrap(model.groups(.left).first)
        await client.loseNextResponse(); await model.toggle(group, enabled: false)
        XCTAssertFalse(model.loaded); XCTAssertTrue(model.error?.contains("could not be confirmed") == true)
        await model.toggle(group, enabled: false)
        var writes = await client.writes; XCTAssertEqual(writes.count, 1)
        await client.fail(true); await model.refresh(); XCTAssertFalse(model.loaded)
        await client.fail(false); await model.refresh(); XCTAssertTrue(model.loaded)
        XCTAssertEqual(model.rows.first?.enabled, false)
        writes = await client.writes; XCTAssertEqual(writes.count, 1, "Readback must not repeat the mutation")
    }
    func testGroupsPreservePausedDifferentWindowsSidesAndSnoozeSettings() {
        var alternate = row(5, day: .friday); alternate.snoozeTaper = 60
        var right = row(6); right.side = .right
        let rows = [row(), row(2, day: .tuesday), row(3, enabled: false), row(4, window: 10), alternate, right]
        let groups = AlarmGroup.group(rows, side: .left)
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups[0].rows.map(\.id), [1, 2])
        let draft = AlarmDraft(group: groups[0])
        XCTAssertEqual(draft.days, [.monday, .tuesday])
        XCTAssertEqual(draft.snoozeDuration, 540); XCTAssertEqual(draft.snoozeTaper, 30)
        XCTAssertEqual(draft.snoozePreview, "9, 6.3, 4.4, 3.1 min")
        XCTAssertEqual(draft.creates.first?.vibrationPattern, .double)
    }
    func testLegacyAlarmDecodingAndWallClockWindow() throws {
        let legacy = Data(#"{"vibrationIntensity":50,"vibrationPattern":"rise","duration":30,"time":"00:10","enabled":true,"alarmTemperature":80}"#.utf8)
        let alarm = try JSONDecoder().decode(AlarmSchedule.self, from: legacy)
        XCTAssertNil(alarm.wakeWindow); XCTAssertNil(alarm.snoozeDuration)
        var draft = AlarmDraft(sides: [.left]); draft.time = "00:10"; draft.wakeWindow = 30
        XCTAssertEqual(draft.windowStart, "23:40")
        XCTAssertNotNil(draft.validation)
        draft.days = [.monday]; XCTAssertNil(draft.validation)
        for invalid in ["24:00", "6:30", "06:60", "NaN", "07:00:00"] { draft.time = invalid; XCTAssertNotNil(draft.validation) }
    }
    func testNextAlarmUsesPodTimezoneAcrossDSTAndSkipsPausedRows() throws {
        var sunday = row(day: .sunday); sunday.time = "02:30"
        let group = AlarmGroup(rows: [sunday])
        let formatter = ISO8601DateFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2026-03-08T09:00:00Z"))
        let next = try XCTUnwrap(group.nextDate(after: now, timeZone: TimeZone(identifier: "America/Los_Angeles")!))
        XCTAssertEqual(formatter.string(from: next), "2026-03-08T10:30:00Z", "Core shifts spring-forward 02:30 without dropping its minutes")
        sunday.enabled = false
        XCTAssertNil(AlarmGroup(rows: [sunday]).nextDate(after: now, timeZone: .gmt))
    }
    func testNextAlarmDoesNotRepeatTheFallBackHourAndSkipsMissingCalendarMidnight() throws {
        let formatter = ISO8601DateFormatter()
        var sunday = row(day: .sunday); sunday.time = "01:30"
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let next = try XCTUnwrap(AlarmGroup(rows: [sunday]).nextDate(after: formatter.date(from: "2026-11-01T08:45:00Z")!, timeZone: losAngeles))
        XCTAssertEqual(formatter.string(from: next), "2026-11-08T09:30:00Z", "Core runs the first repeated wall-clock occurrence only")
        sunday.time = "00:30"
        let missingMidnight = try XCTUnwrap(AlarmGroup(rows: [sunday]).nextDate(after: formatter.date(from: "2018-11-04T02:00:00Z")!, timeZone: TimeZone(identifier: "America/Sao_Paulo")!))
        XCTAssertEqual(formatter.string(from: missingMidnight), "2018-11-11T02:30:00Z")
    }
    func testCurvePatchPreservesExtraPausedAlarmsAndUntouchedPowerRows() throws {
        let rows = CoreScheduleRows(temperature: [CoreTemperatureRow(id: 20, side: "left", dayOfWeek: "monday", time: "22:00", temperature: 72, enabled: true)],
            power: [CorePowerRow(id: 30, side: "left", dayOfWeek: "monday", onTime: "22:00", offTime: "07:00", onTemperature: 72, enabled: false, endAction: .maintain, offDayOffset: 1)],
            alarm: [row(), row(2, enabled: false)])
        var native = rows.projected
        var patch = CoreSchedulePatch()
        try patch.append(requested: native, latest: rows, side: .left, days: [.monday])
        XCTAssertTrue(patch.isEmpty)
        native.monday.temperatures["22:00"] = 68
        try patch.append(requested: native, latest: rows, side: .left, days: [.monday])
        let updates = try XCTUnwrap(patch.input["updates"] as? [String: [[String: Any]]])
        XCTAssertEqual(updates["temperature"]?.first?["id"] as? Int, 20)
        XCTAssertTrue(updates["alarm"]!.isEmpty); XCTAssertTrue(updates["power"]!.isEmpty)
        XCTAssertNil((patch.input["deletes"] as? [String: Any])?["alarm"])
    }
    func testCompactAlarmEditOnlyTouchesRepresentativeRowAndRejectsChangedSource() throws {
        let original = CoreScheduleRows(alarm: [row(), row(2, enabled: false)])
        var native = original.projected; native.monday.alarm.enabled = false
        var patch = CoreSchedulePatch()
        try patch.append(requested: native, latest: original, side: .left, days: [.monday])
        let updates = try XCTUnwrap(patch.input["updates"] as? [String: [[String: Any]]])
        let alarms = try XCTUnwrap(updates["alarm"])
        XCTAssertEqual(alarms.count, 1); XCTAssertEqual(alarms[0]["id"] as? Int, 1)
        XCTAssertEqual(alarms[0]["wakeWindow"] as? Int, 20)
        XCTAssertEqual(alarms[0]["snoozeDuration"] as? Int, 540)
        XCTAssertEqual(alarms[0]["snoozeTaper"] as? Int, 30)
        var latest = original; latest.alarm[0].time = "06:45"
        XCTAssertThrowsError(try patch.append(requested: native, latest: latest, side: .left, days: [.monday]))
    }
    func testOvernightPowerEditsPreserveCalendarOffsetsAndInferNewWindows() throws {
        let original = CoreScheduleRows(power: [CorePowerRow(id: 30, side: "left", dayOfWeek: "monday", onTime: "22:00", offTime: "07:00", onTemperature: 72, enabled: true, endAction: .maintain, offDayOffset: 1)])
        var native = original.projected; native.monday.power.enabled = false
        var patch = CoreSchedulePatch()
        try patch.append(requested: native, latest: original, side: .left, days: [.monday])
        let updates = try XCTUnwrap(patch.input["updates"] as? [String: [[String: Any]]])
        XCTAssertEqual(updates["power"]?.first?["offDayOffset"] as? Int, 1)
        native = CoreScheduleRows().projected
        native.monday.power = PowerSchedule(on: "22:00", off: "07:00", endAction: .turnOff, onTemperature: 72, enabled: true)
        var newPatch = CoreSchedulePatch()
        try newPatch.append(requested: native, latest: CoreScheduleRows(), side: .left, days: [.monday])
        let creates = try XCTUnwrap(newPatch.input["creates"] as? [String: [[String: Any]]])
        XCTAssertEqual(creates["power"]?.first?["offDayOffset"] as? Int, 1)
    }
    func testScheduleSaveErrorSurvivesRecoveryRefresh() async throws {
        let model = ScheduleManager(api: ScheduleFailureClient())
        await model.fetchSchedules()
        await model.togglePowerSchedule()
        XCTAssertTrue(model.error?.contains("Schedule changed on another device") == true)
        await model.fetchSchedules()
        XCTAssertNil(model.error)
    }
    func testCreateBothSidesEditPausedGroupToggleAndDeletePreserveOtherAlarms() async throws {
        let client = AlarmRecordingClient(rows: [row(1, enabled: false), row(2, day: .sunday)])
        let model = AlarmWorkspace(api: client, demo: true); await model.refresh()
        var draft = AlarmDraft(group: model.groups(.left).first { !$0.alarm.enabled }!)
        draft.sides = [.left, .right]; draft.days = [.monday, .tuesday]; draft.wakeWindow = 30
        let saved = await model.save(draft); XCTAssertTrue(saved)
        XCTAssertEqual(model.rows.count, 5)
        XCTAssertTrue(model.rows.contains(row(2, day: .sunday)))
        XCTAssertEqual(model.rows.filter { !$0.enabled }.count, 4)
        XCTAssertEqual(model.rows.last?.snoozeTaper, 30)
        let right = try XCTUnwrap(model.groups(.right).first)
        await model.toggle(right, enabled: true)
        XCTAssertEqual(model.rows.filter { $0.side == .right && $0.enabled }.count, 2)
        let removed = await model.delete(model.groups(.right)[0]); XCTAssertTrue(removed)
        XCTAssertTrue(model.groups(.right).isEmpty)
        XCTAssertTrue(model.rows.contains(row(2, day: .sunday)))
    }
    func testConcurrentEditAndNetworkFailureDoNotDiscardRowsOrCloseDraft() async throws {
        let client = AlarmRecordingClient(rows: [row()])
        let model = AlarmWorkspace(api: client); await model.refresh()
        var draft = AlarmDraft(group: model.groups(.left)[0]); draft.wakeWindow = 30
        var changed = row(); changed.time = "06:00"; await client.replace([changed])
        var saved = await model.save(draft); XCTAssertFalse(saved)
        XCTAssertTrue(model.error?.contains("another device") == true)
        let writes = await client.writes; XCTAssertTrue(writes.isEmpty)
        await model.refresh()
        draft = AlarmDraft(group: model.groups(.left)[0]); draft.duration = 60
        await client.fail(true)
        saved = await model.save(draft); XCTAssertFalse(saved)
        XCTAssertEqual(model.rows, [changed]); XCTAssertNotNil(model.error)
    }
    func testVibrationOnlyRunsOnExplicitTestAndStopRemainsAvailableWhileSending() async {
        let client = AlarmRecordingClient(rows: [row()])
        let model = AlarmWorkspace(api: client); await model.refresh()
        var draft = AlarmDraft(group: model.groups(.left)[0]); draft.sides = [.left, .right]
        let saved = await model.save(draft); XCTAssertTrue(saved)
        var tests = await client.tests; XCTAssertTrue(tests.isEmpty)
        await client.holdTest()
        let testing = Task { await model.test(draft) }
        await client.waitForTest()
        await model.stopTest()
        await client.releaseTest(); await testing.value
        tests = await client.tests
        let stops = await client.stops
        XCTAssertEqual(tests.map(\.side), [.left], "Stop cancels the unsent other-side test")
        XCTAssertEqual(stops, [.left]); XCTAssertEqual(model.notice, "Vibration test stopped.")
    }
    func testRESTAlarmRequestsUseFahrenheitAtomicBatchAndExplicitStop() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AlarmRequestProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let client = CoreAlarmClient(client: CoreRESTClient(endpoint: URL(string: "https://alarm-contract.invalid")!, session: session))
        let rows = try await client.all(); XCTAssertEqual(rows.count, 0)
        var draft = AlarmDraft(sides: [.right]); draft.days = [.tuesday]; draft.wakeWindow = 20; draft.snoozeDuration = 540; draft.snoozeTaper = 40
        try await client.apply(AlarmBatch(creates: draft.creates, deletes: [7], updates: [AlarmToggle(id: 8, enabled: false)]))
        try await client.test(AlarmJob(side: .right, vibrationIntensity: 100, vibrationPattern: .rise, duration: 30))
        try await client.stop(.right)
    }
}

private final class ScheduleFailureClient: MockAPIClient, @unchecked Sendable {
    override func getSchedules() async throws -> Schedules { try await MockClient().getSchedules() }
    override func updateSchedules(_ schedules: Schedules, days: Set<DayOfWeek>?) async throws -> Schedules {
        throw APIError.serverError(message: "Schedule changed on another device")
    }
}

private actor AlarmRecordingClient: AlarmClient {
    var rows: [CoreAlarmRow]
    var writes: [AlarmBatch] = []
    var tests: [AlarmJob] = []
    var stops: [Side] = []
    private var failure = false
    private var loseResponse = false
    func loseNextResponse() { loseResponse = true }
    private var hold = false
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    init(rows: [CoreAlarmRow]) { self.rows = rows }
    func replace(_ rows: [CoreAlarmRow]) { self.rows = rows }
    func fail(_ value: Bool) { failure = value }
    func all() throws -> [CoreAlarmRow] { if failure { throw URLError(.notConnectedToInternet) }; return rows }
    func apply(_ batch: AlarmBatch) throws {
        if failure { throw URLError(.timedOut) }
        writes.append(batch); rows.removeAll { batch.deletes.contains($0.id) }
        for update in batch.updates { if let index = rows.firstIndex(where: { $0.id == update.id }) { rows[index].enabled = update.enabled } }
        for create in batch.creates { rows.append(create.row(id: (rows.map(\.id).max() ?? 0) + 1)) }
        if loseResponse { loseResponse = false; throw URLError(.timedOut) }
    }
    func holdTest() { hold = true }
    func waitForTest() async { if tests.isEmpty { await withCheckedContinuation { started = $0 } } }
    func releaseTest() { release?.resume(); release = nil }
    func test(_ job: AlarmJob) async {
        tests.append(job); started?.resume(); started = nil
        if hold { await withCheckedContinuation { release = $0 } }
    }
    func stop(_ side: Side) { stops.append(side) }
}

private final class AlarmRequestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(buffer, count: count) }
        }
        let input = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        var valid = false; var response = Data(#"{"success":true}"#.utf8)
        switch request.url?.path {
        case "/api/schedules":
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            valid = request.httpMethod == "GET" && query?.contains(URLQueryItem(name: "unit", value: "F")) == true
            response = Data(#"{"temperature":[],"power":[],"alarm":[]}"#.utf8)
        case "/api/schedules/batch":
            let creates = (input?["creates"] as? [String: Any])?["alarm"] as? [[String: Any]]
            let deletes = (input?["deletes"] as? [String: Any])?["alarm"] as? [Int]
            let updates = (input?["updates"] as? [String: Any])?["alarm"] as? [[String: Any]]
            valid = request.httpMethod == "POST" && creates?.count == 1 && creates?.first?["id"] == nil
                && creates?.first?["wakeWindow"] as? Int == 20 && creates?.first?["snoozeDuration"] as? Int == 540
                && creates?.first?["snoozeTaper"] as? Int == 40 && deletes == [7] && updates?.first?["enabled"] as? Bool == false
        case "/api/device/alarm": valid = request.httpMethod == "POST" && input?.count == 4 && input?["side"] as? String == "right" && input?["duration"] as? Int == 30
        case "/api/device/alarm/clear": valid = request.httpMethod == "POST" && input?.count == 1 && input?["side"] as? String == "right"
        default: break
        }
        guard valid, let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
