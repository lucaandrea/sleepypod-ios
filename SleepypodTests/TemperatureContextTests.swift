import XCTest
@testable import Sleepypod

@MainActor final class TemperatureContextTests: XCTestCase {
    private func client(_ host: String = "context-complete.invalid") -> CoreTemperatureContextClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TemperatureContextProtocol.self]
        return CoreTemperatureContextClient(transport: CoreRESTClient(endpoint: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration)))
    }

    func testCelsiusEnvironmentAndRightSideSleepUseExactSessionWindow() async throws {
        let result = await client().load(side: .right)
        XCTAssertNil(result.room.error); XCTAssertNil(result.sleep.error)
        XCTAssertEqual(result.room.value?.ambientTemp, 25)
        XCTAssertEqual(result.room.value?.bedAir(side: .right), 28)
        XCTAssertEqual(result.room.value?.bedAir(side: .left), 25)
        let sleep = try XCTUnwrap(result.sleep.value)
        XCTAssertEqual(sleep.record.side, "right"); XCTAssertEqual(sleep.record.sleepPeriodSeconds, 28800)
        XCTAssertEqual(sleep.vitals.value?.avgHeartRate, 58)
        XCTAssertEqual(sleep.vitals.value?.comparableHRV, 44)
        XCTAssertTrue(sleep.vitals.value?.note.contains("rmssd") == true)
    }

    func testOpenSleepOmitsEndDateInsteadOfChangingSessionWithClientClock() async {
        let result = await client("context-open.invalid").load(side: .right)
        XCTAssertTrue(result.sleep.value?.record.isOngoing == true)
        XCTAssertEqual(result.sleep.value?.vitals.value?.recordCount, 120)
    }

    func testIndependentFailuresDoNotHideAvailableRoomOrSleepRecords() async {
        let result = await client("context-partial.invalid").load(side: .right)
        XCTAssertNotNil(result.room.value); XCTAssertNil(result.room.error)
        XCTAssertTrue(result.light.error?.contains("light pipeline unavailable") == true)
        XCTAssertNotNil(result.sleep.value?.record)
        XCTAssertTrue(result.sleep.value?.vitals.error?.contains("vitals pipeline unavailable") == true)
    }

    func testMissingValuesStayMissingAndDoNotTriggerAnUnboundedVitalsRequest() async {
        let result = await client("context-empty.invalid").load(side: .right)
        XCTAssertNil(result.room.value); XCTAssertNil(result.room.error)
        XCTAssertNil(result.light.value); XCTAssertNil(result.sleep.value); XCTAssertNil(result.sleep.error)
    }

    func testInvalidOrWrongSideSessionCannotPopulateSelectedSleeper() async {
        for host in ["context-wrong-side.invalid", "context-bad-date.invalid"] {
            let result = await client(host).load(side: .right)
            XCTAssertNil(result.sleep.value)
            XCTAssertTrue(result.sleep.error?.contains("invalid sleep session") == true)
        }
    }

    func testStaleUnknownAndFutureSensorDatesAreNotCurrent() {
        let now = Date(timeIntervalSince1970: 1800000000)
        XCTAssertTrue(RoomSnapshot.isFresh(now.addingTimeInterval(-119), now: now))
        XCTAssertFalse(RoomSnapshot.isFresh(now.addingTimeInterval(-120), now: now))
        XCTAssertFalse(RoomSnapshot.isFresh(now.addingTimeInterval(10), now: now))
        XCTAssertFalse(RoomSnapshot.isFresh(nil, now: now))
        let room = RoomSnapshot(timestamp: "invalid", ambientTemp: nil, humidity: nil, leftOuterTemp: .nan, leftCenterTemp: nil, leftInnerTemp: nil,
                                rightOuterTemp: 25, rightCenterTemp: 27, rightInnerTemp: nil)
        XCTAssertNil(room.date); XCTAssertNil(room.bedAir(side: .left)); XCTAssertEqual(room.bedAir(side: .right), 26)
    }

    func testIncompatibleHRVDefinitionsRemainOmittedEvenIfServerReturnsAnAverage() async throws {
        let result = await client("context-mixed.invalid").load(side: .right)
        let vitals = try XCTUnwrap(result.sleep.value?.vitals.value)
        XCTAssertEqual(vitals.avgHRV, 44); XCTAssertNil(vitals.comparableHRV)
        XCTAssertTrue(vitals.note.contains("definitions differ"))
    }

    func testOldSideResponseCannotOverwriteNewSide() async {
        let workspace = TemperatureContextWorkspace()
        let slow = Task { await workspace.load(side: .left, client: DelayedContextClient()) }
        try? await Task.sleep(for: .milliseconds(20))
        await workspace.load(side: .right, client: DelayedContextClient())
        await slow.value
        XCTAssertEqual(workspace.side, .right)
        XCTAssertEqual(workspace.result?.sleep.value?.record.side, "right")
        XCTAssertFalse(workspace.loading)
    }
}

private struct DelayedContextClient: TemperatureContextClient {
    func load(side: Side) async -> TemperatureContextResult {
        if side == .left { try? await Task.sleep(for: .milliseconds(150)) }
        return await DemoTemperatureContextClient().load(side: side)
    }
}

private final class TemperatureContextProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasPrefix("context-") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        XCTAssertEqual(request.httpMethod, "GET")
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let host = url.host ?? ""
        var status = 200
        var body = "null"
        switch url.path {
        case "/api/environment/bed-temp/latest":
            XCTAssertEqual(query, ["unit": "C"])
            if host != "context-empty.invalid" {
                body = #"{"timestamp":"2026-10-25T23:00:00.000Z","ambientTemp":25,"humidity":55,"leftOuterTemp":24,"leftCenterTemp":null,"leftInnerTemp":26,"rightOuterTemp":27,"rightCenterTemp":28,"rightInnerTemp":29}"#
            }
        case "/api/environment/ambient-light/latest":
            XCTAssertTrue(query.isEmpty)
            if host == "context-partial.invalid" { status = 503; body = #"{"message":"light pipeline unavailable"}"# }
            else if host != "context-empty.invalid" { body = #"{"timestamp":"2026-10-25T23:00:00Z","lux":4}"# }
        case "/api/biometrics/sleep-records/latest":
            XCTAssertEqual(query, ["side": "right"])
            if host != "context-empty.invalid" {
                let side = host == "context-wrong-side.invalid" ? "left" : "right"
                let start = host == "context-bad-date.invalid" ? "invalid" : "2026-10-25T06:00:00.000Z"
                let end = host == "context-open.invalid" ? "null" : "\"2026-10-25T14:00:00.000Z\""
                body = "{\"id\":7,\"side\":\"\(side)\",\"enteredBedAt\":\"\(start)\",\"leftBedAt\":\(end),\"sleepDurationSeconds\":28800,\"timesExitedBed\":2}"
            }
        case "/api/biometrics/vitals/summary":
            XCTAssertFalse(["context-empty.invalid", "context-wrong-side.invalid", "context-bad-date.invalid"].contains(host))
            XCTAssertEqual(query["side"], "right"); XCTAssertEqual(query["startDate"], "2026-10-25T06:00:00Z")
            XCTAssertEqual(query["endDate"], host == "context-open.invalid" ? nil : "2026-10-25T14:00:00Z")
            if host == "context-partial.invalid" { status = 503; body = #"{"message":"vitals pipeline unavailable"}"# }
            else {
                let aggregation = host == "context-mixed.invalid" ? "incompatible_definitions" : "single_definition"
                body = "{\"avgHeartRate\":58,\"avgHRV\":44,\"avgBreathingRate\":14,\"recordCount\":120,\"provenance\":{\"configurationCount\":1,\"unknownConfigurationRows\":0,\"hrvMetricId\":\"rmssd\",\"hrvAggregation\":\"\(aggregation)\"}}"
            }
        default: XCTFail("Unexpected context request: \(url.path)")
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
