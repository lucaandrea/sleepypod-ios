import XCTest
@testable import Sleepypod

@MainActor final class SensorCalibrationTests: XCTestCase {
    func testValidityIsUnknownWithoutDatesAndClampedAcrossExpiry() throws {
        let profile = try calibrationFixture().piezo!
        let middle = SensorCalibrationProfile.date("2026-10-25T12:00:00Z")!
        XCTAssertEqual(profile.validity(at: middle)?.remaining, 0.5)
        XCTAssertEqual(profile.validity(at: middle.addingTimeInterval(2 * 86400))?.remaining, 0)
        XCTAssertEqual(profile.validity(at: middle.addingTimeInterval(-2 * 86400))?.remaining, 1)
        XCTAssertNil(try calibrationFixture(created: nil).piezo?.validity(at: middle))
    }
    func testCapacitanceCompensatesReferenceAndRejectsMissingChannels() throws {
        let data = Data(#"{"format":"capSense2","threshold":6,"channels":{"A":{"mean":10,"std":0.1},"B":{"mean":20,"std":0.2},"C":{"mean":30,"std":0.2}},"ref":{"mean":1.2}}"#.utf8)
        let parameters = try JSONDecoder().decode(CalibrationParameters.self, from: data)
        let baseline = try XCTUnwrap(parameters.capacitance)
        let values = [10.1, 10.1, 20.1, 20.1, 32.1, 32.1, 1.3, 1.3]
        XCTAssertEqual(try XCTUnwrap(baseline.deviation(values)?.reduce(0, +)), 2, accuracy: 0.0001)
        XCTAssertEqual(baseline.channelsInBaseline(values), 2)
        XCTAssertEqual(baseline.band, 0.9, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(baseline.deviation([11, 11, 20, 20, 30, 30])?.reduce(0, +)), 1, accuracy: 0.0001)
        XCTAssertNil(baseline.deviation([-1, 11, 20, 20, 30, 30])); XCTAssertNil(baseline.deviation([1, 2]))
    }
    func testTemperatureBaselinesConvertCentidegreesAndKeepMissingZonesUnknown() throws {
        let parameters = try JSONDecoder().decode(CalibrationParameters.self, from: Data(#"{"ambient_mean":2200,"offsets":{"left_outer_temp":100,"left_center_temp":250,"left_inner_temp":-50}}"#.utf8))
        XCTAssertEqual(parameters.temperatureMeans(side: .left), ["outer": 23, "center": 24.5, "inner": 21.5])
        XCTAssertTrue(parameters.temperatureMeans(side: .right).isEmpty)
        let malformed = try JSONDecoder().decode(CalibrationParameters.self, from: Data(#"{"baseline_mean_range":"bad","presence_threshold":50000,"format":"capSense","channels":{}}"#.utf8))
        XCTAssertNil(malformed.piezo); XCTAssertNil(malformed.capacitance)
    }
    func testPiezoEnvelopeRemovesDCAndEmptyFramesRemainEmpty() {
        let time = Date(timeIntervalSince1970: 100)
        let envelope = CalibrationSignalBuffer.envelope([.init(time: time, samples: [100, 104, 96, 100])], buckets: 2)
        XCTAssertEqual(envelope.count, 2); XCTAssertEqual(envelope[0].low, 0); XCTAssertEqual(envelope[0].high, 4)
        XCTAssertEqual(envelope[1].low, -4); XCTAssertLessThan(envelope[0].time, envelope[1].time)
        XCTAssertLessThanOrEqual(envelope[1].time, time)
        XCTAssertNil(CalibrationSignalBuffer.range([])); XCTAssertEqual(CalibrationSignalBuffer.range([3, -2, 7]), 9)
    }
    func testSignalWindowsStayBoundedAndSentinelsDoNotBecomeTemperature() {
        var buffer = CalibrationSignalBuffer()
        let start = Date(timeIntervalSince1970: 1000)
        for second in 0..<200 {
            let time = start.addingTimeInterval(Double(second))
            buffer.append(.piezoDual(.init(ts: second, freq: 500, left1: [10, 20], right1: [])), at: time)
            buffer.append(.capSense2(.init(ts: second, left: .init(values: [1, 2], status: "good"), right: .init(values: [], status: "bad"))), at: time)
        }
        XCTAssertEqual(buffer.piezo[.left]?.count, 31); XCTAssertEqual(buffer.piezo[.right]?.count, 0)
        XCTAssertEqual(buffer.capacitance[.left]?.count, 31)
        buffer.append(.bedTemp2(.init(ts: 1, mcu: nil, left: .init(amb: 22, hu: 50, temps: [25, -327, 26]), right: .init(amb: 22, hu: 50, temps: []))), at: start)
        XCTAssertEqual(buffer.temperature[.left]?.last?.zones, [25, nil, 26])
        XCTAssertEqual(buffer.temperature[.right]?.last?.zones, [nil, nil, nil])
    }
    func testOldSuccessfulProfilesNeverConfirmANewFullCalibration() async throws {
        let client = try CalibrationFixtureClient()
        let model = SensorCalibrationWorkspace(client: client)
        await model.refresh(); XCTAssertTrue(model.canTrigger)
        await model.trigger(nil); await model.refresh()
        XCTAssertEqual(model.waiting.count, 6); XCTAssertFalse(model.completed)
        await client.set(try calibrationFixture(created: "2026-10-25T13:00:00Z"))
        await model.refresh(); XCTAssertTrue(model.completed); XCTAssertTrue(model.waiting.isEmpty)
    }
    func testFailedOrMissingResultsCannotShowSuccess() async throws {
        let client = try CalibrationFixtureClient()
        let model = SensorCalibrationWorkspace(client: client)
        await model.refresh(); await model.trigger(nil)
        await client.set(try calibrationFixture(created: "2026-10-25T13:00:00Z", failed: .temperature))
        await model.refresh()
        XCTAssertFalse(model.completed); XCTAssertTrue(model.waiting.isEmpty)
        XCTAssertTrue(model.actionError?.contains("temperature fixture failure") == true)
        await model.trigger(nil)
        await client.set(try calibrationFixture(created: nil))
        await model.refresh(); XCTAssertFalse(model.completed); XCTAssertEqual(model.waiting.count, 6)
    }
    func testRejectedTriggerIsVisibleAndDoesNotPollForSuccess() async throws {
        let client = try CalibrationFixtureClient(accepted: false)
        let model = SensorCalibrationWorkspace(client: client)
        await model.refresh(); await model.trigger(.init(side: .left, kind: .piezo))
        XCTAssertTrue(model.actionError?.contains("fixture rejected") == true); XCTAssertFalse(model.completed); XCTAssertTrue(model.waiting.isEmpty)
    }
    func testTimeoutAndReadFailureRetainUnknownOutcome() async throws {
        let client = try CalibrationFixtureClient()
        let model = SensorCalibrationWorkspace(client: client)
        let start = Date.now
        await model.refresh(now: start); await model.trigger(nil, now: start)
        await client.failReads()
        await model.refresh(now: start.addingTimeInterval(121))
        XCTAssertFalse(model.completed); XCTAssertNotNil(model.actionError)
        XCTAssertNotNil(model.errors[.left]); XCTAssertFalse(model.canTrigger)
    }
    func testTransportUsesExactStatusAndTriggerContracts() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CalibrationFixtureProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let client = CoreSensorCalibrationClient(transport: .init(endpoint: URL(string: "https://calibration-test.invalid")!, session: session))
        let status = try await client.status(.right); XCTAssertEqual(status.piezo?.status, "completed")
        let single = try await client.trigger(.init(side: .right, kind: .temperature)); XCTAssertTrue(single.triggered)
        let all = try await client.trigger(nil); XCTAssertTrue(all.triggered)
    }
    func testLegacyAndCurrentWireFramesPreserveUnitsAndMissingChannels() throws {
        let legacy = Data(#"{"type":"bedTemp","ts":1,"amb":2200,"hu":4500,"left":{"out":2300,"cen":-32768,"in":2400},"right":{"out":2500}}"#.utf8)
        guard case .bedTemp(let frame) = SensorFrame.decode(from: legacy) else { return XCTFail("Legacy temperature was dropped") }
        XCTAssertEqual(frame.left.amb, 22); XCTAssertEqual(frame.left.hu, 45)
        XCTAssertEqual(frame.left.temps, [23, -327.68, 24]); XCTAssertNil(frame.mcu)
        let current = Data(#"{"type":"bedTemp2","ts":2,"left":{"temps":[23,24,25]},"right":{"temps":[]}}"#.utf8)
        guard case .bedTemp2(let currentFrame) = SensorFrame.decode(from: current) else { return XCTFail("Missing ambient discarded surface values") }
        XCTAssertNil(currentFrame.left.amb); XCTAssertEqual(currentFrame.left.temps, [23, 24, 25])
        let cap = Data(#"{"type":"capSense","ts":3,"left":{"out":10,"in":30},"right":[1,2,3]}"#.utf8)
        guard case .capSense(let capFrame) = SensorFrame.decode(from: cap) else { return XCTFail("Legacy capacitance was dropped") }
        XCTAssertEqual(capFrame.left.values, [10, 10, -1, -1, 30, 30]); XCTAssertEqual(capFrame.right.values, [1, 2, 3])
        XCTAssertEqual(capFrame.left.status, "unknown")
    }
}

private func calibrationData(created: String? = "2026-10-24T12:00:00Z", failed: CalibrationKind? = nil) throws -> Data {
    var object: [String: Any] = [:]
    for (index, kind) in CalibrationKind.allCases.enumerated() {
        object[kind.rawValue] = ["id": index, "side": "left", "sensorType": kind.rawValue, "status": failed == kind ? "failed" : "completed", "createdAt": created as Any? ?? NSNull(), "expiresAt": "2026-10-26T12:00:00Z", "qualityScore": 0.91, "samplesUsed": 1000, "errorMessage": failed == kind ? "\(kind.rawValue) fixture failure" : NSNull(), "parameters": [:]] as [String: Any]
    }
    return try JSONSerialization.data(withJSONObject: object)
}
private func calibrationFixture(created: String? = "2026-10-24T12:00:00Z", failed: CalibrationKind? = nil) throws -> SensorCalibrationStatus {
    try JSONDecoder().decode(SensorCalibrationStatus.self, from: calibrationData(created: created, failed: failed))
}
private actor CalibrationFixtureClient: SensorCalibrationClient {
    private var result: SensorCalibrationStatus
    private let accepted: Bool
    private var failure = false
    init(accepted: Bool = true) throws { result = try calibrationFixture(); self.accepted = accepted }
    func set(_ status: SensorCalibrationStatus) { result = status }
    func failReads() { failure = true }
    func status(_ side: Side) throws -> SensorCalibrationStatus { if failure { throw APIError.noBaseURL }; return result }
    func trigger(_ target: CalibrationTarget?) -> CalibrationTriggerResponse { .init(triggered: accepted, message: accepted ? "queued" : "fixture rejected") }
}
private final class CalibrationFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "calibration-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        do {
            let data: Data
            if url.path == "/api/calibration/status" {
                XCTAssertEqual(request.httpMethod, "GET"); XCTAssertEqual(url.query, "side=right")
                data = try calibrationData()
            } else {
                XCTAssertEqual(request.httpMethod, "POST")
                var body = request.httpBody
                if body == nil, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var bytes = [UInt8](repeating: 0, count: 1024); var collected = Data()
                    while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; collected.append(contentsOf: bytes.prefix(count)) }
                    body = collected
                }
                let values = try JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: String]
                if url.path == "/api/calibration/trigger" { XCTAssertEqual(values, ["side": "right", "sensorType": "temperature"]) }
                else { XCTAssertEqual(url.path, "/api/calibration/trigger-all"); XCTAssertEqual(values, [:]) }
                data = Data(#"{"triggered":true,"message":"queued"}"#.utf8)
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
