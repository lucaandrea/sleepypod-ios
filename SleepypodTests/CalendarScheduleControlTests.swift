import XCTest
@testable import Sleepypod

@MainActor final class CalendarScheduleControlTests: XCTestCase {
    private func example() -> CoreScheduleRows {
        .init(temperature: [.init(id: 1, side: "left", dayOfWeek: "monday", time: "22:15", temperature: 72, enabled: false),
                            .init(id: 2, side: "left", dayOfWeek: "sunday", time: "02:30", temperature: 68, enabled: true)],
              power: [.init(id: 3, side: "left", dayOfWeek: "friday", onTime: "23:00", offTime: "07:00", onTemperature: 74, enabled: true, endAction: .maintain, offDayOffset: 1)],
              alarm: [.init(id: 4, side: .left, dayOfWeek: .tuesday, time: "06:45", vibrationIntensity: 40, vibrationPattern: .rise, duration: 30, alarmTemperature: 82, enabled: false, wakeWindow: 20, snoozeDuration: 540, snoozeTaper: 30)])
    }
    func testGlobalChangePreservesTimesSidesTemperaturesOffsetsAndAlarmOptions() throws {
        let rows = example(), review = CalendarScheduleControl(side: .left, original: example(), enabled: false)
        XCTAssertTrue(CalendarScheduleControl.isEnabled(rows)); XCTAssertFalse(CalendarScheduleControl.isEnabled(review.desired))
        var restored = review.desired
        for index in restored.temperature.indices { restored.temperature[index].enabled = rows.temperature[index].enabled }
        restored.power[0].enabled = rows.power[0].enabled; restored.alarm[0].enabled = rows.alarm[0].enabled
        XCTAssertTrue(CalendarScheduleControl.same(restored, rows))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(review.batch)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["updates"])
        let updates = try XCTUnwrap(object["updates"] as? [String: [[String: Any]]])
        XCTAssertEqual(updates.values.flatMap { $0 }.count, 4)
        for row in updates.values.flatMap({ $0 }) { XCTAssertEqual(Set(row.keys), ["id", "enabled"]); XCTAssertEqual(row["enabled"] as? Bool, false) }
        let resumed = CalendarScheduleControl(side: .left, original: review.desired, enabled: true).desired
        XCTAssertTrue(resumed.temperature.allSatisfy(\.enabled)); XCTAssertTrue(resumed.power.allSatisfy(\.enabled)); XCTAssertTrue(resumed.alarm.allSatisfy(\.enabled))
    }
    func testChangedRowsDuplicateIdentifiersAndWrongSideAreRejected() async {
        let client = CalendarRecordingClient(example()), model = CalendarScheduleWorkspace()
        model.configure(client: client); await model.load([.left])
        var changed = example(); changed.alarm[0].time = "07:30"; await client.replace(changed)
        let saved = await model.apply(.init(side: .left, original: example(), enabled: false))
        XCTAssertFalse(saved); XCTAssertNil(model.rows[.left]); XCTAssertNotNil(model.errors[.left])
        let writes = await client.writes; XCTAssertEqual(writes, 0)
        changed = example(); changed.temperature.append(changed.temperature[0])
        XCTAssertThrowsError(try CalendarScheduleControl.validate(changed, side: .left))
        XCTAssertThrowsError(try CalendarScheduleControl.validate(example(), side: .right))
    }
    func testAcknowledgedButMismatchedReadbackRequiresReloadWithoutReplay() async {
        let client = CalendarRecordingClient(example(), ignoreWrites: true), model = CalendarScheduleWorkspace()
        model.configure(client: client); await model.load([.left])
        let review = CalendarScheduleControl(side: .left, original: example(), enabled: false)
        let first = await model.apply(review), second = await model.apply(review)
        XCTAssertFalse(first); XCTAssertFalse(second); XCTAssertNil(model.rows[.left])
        let writes = await client.writes; XCTAssertEqual(writes, 1)
        await model.load([.left]); XCTAssertNotNil(model.rows[.left])
    }
    func testControllerChangeCancelsPendingBatchAndMissingConnectionHasVisibleError() async {
        let client = CalendarRecordingClient(example()), model = CalendarScheduleWorkspace()
        model.configure(client: client); await model.load([.left]); await client.holdRead()
        let pending = Task { await model.apply(.init(side: .left, original: example(), enabled: false)) }
        await client.waitForRead(); model.invalidate(); model.configure(client: nil)
        await model.load([.right]); await client.releaseRead()
        let result = await pending.value, writes = await client.writes
        XCTAssertFalse(result); XCTAssertEqual(writes, 0); XCTAssertFalse(model.saving); XCTAssertFalse(model.loading)
        XCTAssertNotNil(model.errors[.right]); XCTAssertTrue(model.rows.isEmpty)
    }
    func testDemoPauseAndResumeKeepDisabledTemperatureRows() async throws {
        let api = MockClient(), client = DemoCalendarScheduleClient(api: api)
        let original = try await client.rows(side: .left)
        try await client.apply(.init(side: .left, original: original, enabled: false))
        let paused = try await client.rows(side: .left)
        XCTAssertFalse(CalendarScheduleControl.isEnabled(paused)); XCTAssertEqual(paused.temperature.count, original.temperature.count)
        try await client.apply(.init(side: .left, original: paused, enabled: true))
        let resumed = try await client.rows(side: .left)
        XCTAssertEqual(resumed.temperature.map(\.time), original.temperature.map(\.time)); XCTAssertTrue(resumed.alarm.allSatisfy(\.enabled))
        let untouched = try await client.rows(side: .right); XCTAssertTrue(CalendarScheduleControl.isEnabled(untouched))
    }
    func testRESTRequestsUseFahrenheitAndOnlyEnabledBatchUpdates() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CalendarRequestProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let client = CoreCalendarScheduleClient(transport: .init(endpoint: URL(string: "https://schedule-contract.invalid")!, session: session))
        let rows = try await client.rows(side: .left); XCTAssertEqual(rows.temperature.count, 0)
        try await client.apply(.init(side: .left, original: example(), enabled: false))
    }
}

private actor CalendarRecordingClient: CalendarScheduleClient {
    var value: CoreScheduleRows
    var writes = 0
    let ignoreWrites: Bool
    private var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    init(_ value: CoreScheduleRows, ignoreWrites: Bool = false) { self.value = value; self.ignoreWrites = ignoreWrites }
    func replace(_ value: CoreScheduleRows) { self.value = value }
    func holdRead() { hold = true }
    func waitForRead() async { if continuation == nil { await withCheckedContinuation { observer = $0 } } }
    func releaseRead() { continuation?.resume(); continuation = nil }
    func rows(side: Side) async -> CoreScheduleRows {
        if hold { hold = false; await withCheckedContinuation { continuation = $0; observer?.resume(); observer = nil } }
        return value
    }
    func apply(_ review: CalendarScheduleControl) { writes += 1; if !ignoreWrites { value = review.desired } }
}

private final class CalendarRequestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var valid = false, response = Data(#"{"success":true}"#.utf8)
        if request.httpMethod == "GET" {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            valid = request.url?.path == "/api/schedules" && query?.contains(.init(name: "side", value: "left")) == true && query?.contains(.init(name: "unit", value: "F")) == true
            response = Data(#"{"temperature":[],"power":[],"alarm":[]}"#.utf8)
        } else {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(buffer, count: count) }
            }
            let input = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let rows = (input?["updates"] as? [String: [[String: Any]]])?.values.flatMap { $0 }
            valid = request.httpMethod == "POST" && request.url?.path == "/api/schedules/batch" && rows?.count == 4 && rows?.allSatisfy { Set($0.keys) == ["id", "enabled"] && $0["enabled"] as? Bool == false } == true
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: valid ? 200 : 422, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
