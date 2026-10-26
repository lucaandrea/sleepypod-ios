import XCTest
@testable import Sleepypod

@MainActor final class SystemHealthTests: XCTestCase {
    func testUnknownStatusStaysUnknown() throws {
        XCTAssertEqual(try JSONDecoder().decode(HealthCheckStatus.self, from: Data(#""future-status""#.utf8)), .unknown)
    }
    func testMergedHistoryPreservesGapsAndWorstStatus() {
        let result = SystemHealthHistory.mergedRuns([
            [.init(status: .ok, start: 0, end: 10), .init(status: .ok, start: 20, end: 30)],
            [.init(status: .idle, start: 0, end: 5), .init(status: .down, start: 5, end: 9), .init(status: .stale, start: 21, end: 25)]
        ])
        XCTAssertEqual(result, [
            .init(status: .ok, start: 0, end: 5), .init(status: .down, start: 5, end: 9), .init(status: .ok, start: 9, end: 10),
            .init(status: .ok, start: 20, end: 21), .init(status: .stale, start: 21, end: 25), .init(status: .ok, start: 25, end: 30)
        ])
        XCTAssertFalse(result.contains { $0.start < 20 && $0.end > 10 })
    }
    func testCondensedChecksAndIncidentsKeepTheirMeaning() async throws {
        let history = await DemoSystemHealthClient().history()
        XCTAssertEqual(history.rows(all: true).count, 4)
        XCTAssertEqual(history.rows(all: false).count, 2)
        XCTAssertEqual(history.rows(all: false).first?.label, "Piezo processor · Vitals")
        XCTAssertEqual(history.rows(all: false).last?.label, "2 other checks")
        let incidents = history.incidentLines
        XCTAssertEqual(incidents.count, 3)
        XCTAssertEqual(incidents.first?.tag, "Brief")
        XCTAssertEqual(incidents.filter { $0.title == "Not recorded" }.count, 2)
    }
    func testReadFailureRetainsButDoesNotAuthorizeFromOldSnapshot() async throws {
        let client = HealthFixtureClient()
        let model = SystemHealthWorkspace(client: client, calibration: DemoSensorCalibrationClient())
        await model.refresh()
        XCTAssertTrue(model.mayAct())
        XCTAssertFalse(model.mayAct(at: .now.addingTimeInterval(31)))
        await client.failReads()
        await model.refresh(history: true)
        XCTAssertNotNil(model.path); XCTAssertNotNil(model.history)
        XCTAssertNotNil(model.pathError); XCTAssertNotNil(model.historyError)
        await model.perform(.restart("sleepypod-piezo-processor.service"))
        let calls = await client.restartCount
        XCTAssertEqual(calls, 0); XCTAssertNotNil(model.actionError)
    }
    func testRejectedRestartDoesNotClaimRecovery() async {
        let client = HealthFixtureClient()
        let model = SystemHealthWorkspace(client: client, calibration: DemoSensorCalibrationClient())
        await model.refresh()
        await model.perform(.restart("sleepypod-piezo-processor.service"))
        XCTAssertTrue(model.actionError?.contains("fixture refusal") == true)
        XCTAssertNil(model.actionNotice)
        let calls = await client.restartCount
        XCTAssertEqual(calls, 1)
    }
    func testUnconfirmedRestartRequiresReadbackBeforeAnotherAttempt() async {
        let client = HealthFixtureClient(restartFails: true)
        let model = SystemHealthWorkspace(client: client, calibration: DemoSensorCalibrationClient())
        await model.refresh()
        await model.perform(.restart("sleepypod-piezo-processor.service"))
        XCTAssertTrue(model.actionError?.contains("not confirmed") == true)
        XCTAssertFalse(model.mayAct())
        await model.perform(.restart("sleepypod-piezo-processor.service"))
        let calls = await client.restartCount
        XCTAssertEqual(calls, 1)
        await model.refresh()
        XCTAssertTrue(model.mayAct())
    }
    func testEmptyBedFixWaitsForEachNewProfileAndStopsOnFailure() async {
        let calibration = HealthCalibrationFixture()
        let model = SystemHealthWorkspace(client: DemoSystemHealthClient(), calibration: calibration)
        await model.refresh()
        await model.perform(.calibrate([.right, .left, .left]))
        let targets = await calibration.targets
        XCTAssertEqual(targets, [.init(side: .left, kind: .capacitance), .init(side: .right, kind: .capacitance)])
        XCTAssertNil(model.actionError)
        XCTAssertTrue(model.actionNotice?.contains("New capacitance results received") == true)

        let rejected = HealthCalibrationFixture(reject: true)
        let failed = SystemHealthWorkspace(client: DemoSystemHealthClient(), calibration: rejected)
        await failed.refresh()
        await failed.perform(.calibrate([.left, .right]))
        let rejectedTargets = await rejected.targets
        XCTAssertEqual(rejectedTargets.count, 1)
        XCTAssertTrue(failed.actionError?.contains("fixture rejection") == true)
    }
    func testExactRoutesAndForbiddenRestartNeverReachTransport() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HealthFixtureProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let client = CoreSystemHealthClient(transport: .init(endpoint: URL(string: "https://health-test.invalid")!, session: session))
        let path = try await client.path(); XCTAssertEqual(path.verdict.headline, "fixture")
        let history = try await client.history(); XCTAssertTrue(history.checks.isEmpty)
        let restart = try await client.restart(unit: "sleepypod-piezo-processor.service"); XCTAssertFalse(restart.ok)
        do { _ = try await client.restart(unit: "sleepypod.service"); XCTFail("Forbidden service accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("cannot be restarted")) }
    }
}

private actor HealthFixtureClient: SystemHealthClient {
    private var failing = false
    private let restartFails: Bool
    init(restartFails: Bool = false) { self.restartFails = restartFails }
    private(set) var restartCount = 0
    private let demo = DemoSystemHealthClient()
    func failReads() { failing = true }
    func path() async throws -> SystemHealthPath { if failing { throw APIError.noBaseURL }; return await demo.path() }
    func history() async throws -> SystemHealthHistory { if failing { throw APIError.noBaseURL }; return await demo.history() }
    func restart(unit: String) throws -> HealthServiceRestart {
        restartCount += 1
        if restartFails { throw APIError.noBaseURL }
        return .init(ok: false, message: "fixture refusal")
    }
}
private actor HealthCalibrationFixture: SensorCalibrationClient {
    private let demo = DemoSensorCalibrationClient()
    private let reject: Bool
    private(set) var targets: [CalibrationTarget] = []
    init(reject: Bool = false) { self.reject = reject }
    func status(_ side: Side) async throws -> SensorCalibrationStatus { try await demo.status(side) }
    func trigger(_ target: CalibrationTarget?) async -> CalibrationTriggerResponse {
        if let target { targets.append(target) }
        if reject { return .init(triggered: false, message: "fixture rejection") }
        return await demo.trigger(target)
    }
}
private final class HealthFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "health-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        do {
            let json: String
            switch url.path {
            case "/api/health/data-path":
                XCTAssertEqual(request.httpMethod, "GET")
                json = #"{"at":1000,"occupancy":{"left":"empty","right":"unknown"},"nodes":[],"edges":[],"verdict":{"tone":"ok","headline":"fixture","nodeId":null,"lastGoodId":null,"fix":null,"also":[]}}"#
            case "/api/health/history":
                XCTAssertEqual(request.httpMethod, "GET")
                json = #"{"from":0,"to":1000,"recordedSince":null,"checks":[],"incidents":[],"gaps":[]}"#
            case "/api/health/restart-service":
                XCTAssertEqual(request.httpMethod, "POST")
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
                }
                let body = try JSONDecoder().decode([String: String].self, from: data)
                XCTAssertEqual(body, ["unit": "sleepypod-piezo-processor.service"])
                json = #"{"ok":false,"message":"fixture refusal"}"#
            default: XCTFail("Unexpected request \(url.path)"); throw APIError.noBaseURL
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
