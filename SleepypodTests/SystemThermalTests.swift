import XCTest
@testable import Sleepypod

@MainActor final class SystemThermalTests: XCTestCase {
    func testChartBreaksMissingReadingsAndLongGaps() {
        let points = [ThermalHistoryPoint(timestamp: 0, values: [.leftBed: 68]), .init(timestamp: 1000, values: [:]), .init(timestamp: 2000, values: [.leftBed: 69]), .init(timestamp: 9000, values: [.leftBed: 70])]
        let chart = ThermalChartData(from: 0, to: 9000, gap: 3000, points: points, powerOn: [], available: [:], bedTargetSince: nil)
        let samples = chart.samples(.bedTarget, celsius: true)
        XCTAssertEqual(samples.map(\.segment), [1, 2, 3])
        XCTAssertEqual(samples.first?.value, 20)
        XCTAssertNil(chart.nearest(at: 5400))
        XCTAssertNil(chart.nearest(at: 1000)?.values[.leftBed])
    }
    func testPoweredOffDoesNotCreateLiveTargetOrBedTrace() async {
        let active = await DemoSystemThermalClient().snapshot()
        let off = SystemThermalSnapshot(pumpStallProtectionEnabled: true, reportsPumpSpeed: true, heatsinkTempF: 90, ambientTempF: 72, sides: [.init(side: .left, isPowered: false, targetTempF: 70, currentTempF: 75, isAlarmVibrating: false, poweredOnAt: nil, pumpRpm: 0, flowrate: nil, readingAgeSec: nil, waterTempF: 72, bedSurfaceTempF: nil, guardBlocked: false, verdict: "off", note: nil)])
        let point = off.point(at: .now)
        XCTAssertNil(point.values[.leftTarget]); XCTAssertNil(point.values[.leftBed])
        XCTAssertEqual(point.values[.leftWater], 72); XCTAssertEqual(point.values[.leftRpm], 0)
        XCTAssertEqual(active.sides.first?.direction, "Cooling"); XCTAssertEqual(active.sides.last?.direction, "Warming")
        XCTAssertEqual(off.sides.first?.direction, "Off")
    }
    func testFailedRefreshKeepsLabeledSnapshotAndRangeChangeClearsOldChart() async {
        let client = ThermalFixtureClient()
        let model = SystemThermalWorkspace(client: client)
        await model.refreshSnapshot(); await model.refreshHistory()
        XCTAssertNotNil(model.chart)
        await client.fail()
        await model.refreshSnapshot(); await model.refreshHistory()
        XCTAssertNotNil(model.snapshot); XCTAssertNotNil(model.snapshotError)
        XCTAssertNotNil(model.chart); XCTAssertNotNil(model.historyError)
        model.setRange(.week)
        XCTAssertNil(model.chart); XCTAssertNil(model.history); XCTAssertNil(model.historyError)
    }
    func testLiveWindowHasHardLimitAndUnsupportedSeriesStayAbsent() async {
        let model = SystemThermalWorkspace(client: DemoSystemThermalClient())
        let start = Date.now
        for index in 0..<400 { await model.refreshSnapshot(now: start.addingTimeInterval(Double(index) * 5)) }
        XCTAssertEqual(model.live.count, 360)
        model.setRange(.live)
        XCTAssertEqual(model.chart?.gap, 20_000)
        XCTAssertEqual(model.chart?.available["surface"], true)
    }
    func testMinuteStreamWindowIncludesLegacyTypesAndKeepsLatestSeen() {
        var buffer = SensorStreamActivity()
        let start = Date(timeIntervalSince1970: 1000)
        for index in 0..<1400 { buffer.append(type: "capSense", at: start.addingTimeInterval(Double(index) / 100)) }
        XCTAssertEqual(buffer.ticks.count, 1200)
        let group = SensorStreamActivity.groups.first { $0.id == "presence" }!
        XCTAssertEqual(buffer.recent(group, at: start.addingTimeInterval(15)).count, 1200)
        XCTAssertTrue(buffer.recent(group, at: start.addingTimeInterval(100)).isEmpty)
        XCTAssertEqual(buffer.last["presence"]?.type, "capSense")
        buffer.append(type: "notification", at: start.addingTimeInterval(101))
        XCTAssertEqual(buffer.last.count, 1)
        let malformedReading = Data(#"{"type":"bedTemp2","unexpected":"shape"}"#.utf8)
        XCTAssertNil(SensorFrame.decode(from: malformedReading))
        buffer.append(data: malformedReading, at: start.addingTimeInterval(102))
        XCTAssertEqual(buffer.last["bedTemp"]?.type, "bedTemp2")
    }
    func testLateHistoryCannotReplaceNewRange() async throws {
        let client = DelayedThermalFixture()
        let model = SystemThermalWorkspace(client: client)
        let earlier = Task { await model.refreshHistory() }
        for _ in 0..<100 {
            if await client.waiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let waiting = await client.waiting
        XCTAssertTrue(waiting)
        model.setRange(.week)
        await model.refreshHistory()
        XCTAssertEqual(model.history?.range, "7d")
        await client.finish()
        await earlier.value
        XCTAssertEqual(model.history?.range, "7d")
        XCTAssertFalse(model.loadingHistory)
    }
    func testExactThermalQueriesAndPartialPumpPatch() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ThermalFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let transport = CoreRESTClient(endpoint: URL(string: "https://thermal-test.invalid")!, session: session)
        let thermal = CoreSystemThermalClient(transport: transport)
        let snapshot = try await thermal.snapshot()
        XCTAssertEqual(snapshot.sides.first?.flowrate, 1.2)
        let history = try await thermal.history(.week)
        XCTAssertEqual(history.range, "7d")
        XCTAssertNil(history.points.first?.values[.rightBed])
        do { _ = try await thermal.history(.live); XCTFail("Live history reached transport") }
        catch { XCTAssertTrue(error.localizedDescription.contains("collected in the app")) }
        let pump = CorePumpProtectionClient(transport: transport)
        let saved = try await pump.settings()
        var draft = saved; draft.pumpStallRpmThreshold = 450
        let updated = try await pump.save(draft.patch(from: saved))
        XCTAssertEqual(updated.pumpStallRpmThreshold, 450)
        XCTAssertEqual(updated.pumpStallRecoveryRpm, saved.pumpStallRecoveryRpm)
    }
    func testPumpPatchOnlyChangesEditedFieldsAndRejectsInvalidRanges() async throws {
        let saved = await DemoPumpProtectionClient().settings()
        var draft = saved; draft.pumpStallRpmThreshold = 400
        let patch = draft.patch(from: saved)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Int]
        XCTAssertEqual(object, ["pumpStallRpmThreshold": 400])
        draft.pumpStallRpmThreshold = 20
        XCTAssertThrowsError(try draft.patch(from: saved).validate())
    }
    func testFailedPumpSaveCannotClaimSuccessOrRetryWithoutReadback() async {
        let client = PumpFailureFixture()
        let model = PumpProtectionWorkspace(client: client)
        await model.load(); model.draft?.pumpStallRpmThreshold = 400
        await model.save()
        XCTAssertTrue(model.mustReload); XCTAssertNotNil(model.error); XCTAssertNil(model.notice)
        XCTAssertTrue(model.changed)
        await model.save()
        let calls = await client.saves
        XCTAssertEqual(calls, 1)
        await model.load()
        XCTAssertFalse(model.mustReload); XCTAssertFalse(model.changed)
    }
}

private actor ThermalFixtureClient: SystemThermalClient {
    private let demo = DemoSystemThermalClient()
    private var failed = false
    func fail() { failed = true }
    func snapshot() async throws -> SystemThermalSnapshot { if failed { throw APIError.noBaseURL }; return await demo.snapshot() }
    func history(_ range: ThermalRange) async throws -> SystemThermalHistory { if failed { throw APIError.noBaseURL }; return await demo.history(range) }
}
private actor PumpFailureFixture: PumpProtectionClient {
    private let demo = DemoPumpProtectionClient()
    private(set) var saves = 0
    func settings() async -> PumpProtectionSettings { await demo.settings() }
    func save(_ patch: PumpProtectionPatch) throws -> PumpProtectionSettings { saves += 1; throw APIError.noBaseURL }
}

private actor DelayedThermalFixture: SystemThermalClient {
    private let demo = DemoSystemThermalClient()
    private var pending: CheckedContinuation<SystemThermalHistory, Never>?
    var waiting: Bool { pending != nil }
    func snapshot() async -> SystemThermalSnapshot { await demo.snapshot() }
    func history(_ range: ThermalRange) async -> SystemThermalHistory {
        if range != .twelveHours { return await demo.history(range) }
        return await withCheckedContinuation { pending = $0 }
    }
    func finish() async {
        let result = await demo.history(.twelveHours)
        pending?.resume(returning: result); pending = nil
    }
}
private final class ThermalFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "thermal-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        do {
            let json: String
            let saved = #"{"pumpStallProtectionEnabled":true,"pumpStallRpmThreshold":300,"pumpStallDwellSamples":3,"pumpStallAutoRecoveryEnabled":true,"pumpStallRecoveryRpm":1000,"pumpStallRecoverySamples":3}"#
            switch url.path {
            case "/api/health/thermal":
                XCTAssertEqual(request.httpMethod, "GET")
                json = #"{"pumpStallProtectionEnabled":true,"reportsPumpSpeed":true,"heatsinkTempF":90,"ambientTempF":72,"sides":[{"side":"left","isPowered":true,"targetTempF":68,"currentTempF":70,"isAlarmVibrating":false,"poweredOnAt":null,"pumpRpm":2000,"flowrate":1.2,"readingAgeSec":3,"waterTempF":68,"bedSurfaceTempF":70,"guardBlocked":false,"verdict":"delivering","note":null}]}"#
            case "/api/health/thermal-history":
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "range", value: "7d")])
                json = #"{"range":"7d","from":0,"to":1000,"bucketSec":5,"points":[{"t":0,"leftBed":70,"rightBed":null}],"powerOn":[],"available":{"bedTarget":true},"bedTargetSince":0}"#
            case "/api/settings":
                XCTAssertEqual(request.httpMethod, "GET")
                json = "{\"device\":\(saved)}"
            case "/api/settings/device":
                XCTAssertEqual(request.httpMethod, "PATCH")
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        data.append(contentsOf: buffer.prefix(count))
                    }
                }
                XCTAssertEqual(try JSONDecoder().decode([String: Int].self, from: data), ["pumpStallRpmThreshold": 450])
                json = saved.replacingOccurrences(of: "Threshold\":300", with: "Threshold\":450")
            default: XCTFail("Unexpected request \(url.path)"); throw APIError.noBaseURL
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
