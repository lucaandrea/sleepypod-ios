import XCTest
@testable import Sleepypod

@MainActor final class SensorDiagnosticsTransportTests: XCTestCase {
    func testReadOnlySensorRoutesUnitsAndRanges() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SensorTransportProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = CoreSensorDiagnosticsClient(transport: .init(endpoint: URL(string: "https://sensors.invalid")!, session: session))
        let occupancy = try await client.occupancy()
        XCTAssertFalse(occupancy.left.available)
        XCTAssertEqual(occupancy.left.label, "Unknown")
        XCTAssertEqual(occupancy.right.label, "Light load")
        let bed = try await client.bed()
        XCTAssertEqual(bed?.side(.left).temps, [21, -327.68, 23])
        let freezer = try await client.freezer()
        XCTAssertEqual(freezer?.leftWaterTemp, 21.45)
        XCTAssertNil(freezer?.heatsinkTemp)
        let water = try await client.water()
        XCTAssertNil(water)
        let start = Date(timeIntervalSince1970: 1000), end = Date(timeIntervalSince1970: 22600)
        let history = try await client.history(start: start, end: end, limit: 360)
        XCTAssertEqual(history.first?.leftCenterTemp, 22)
        XCTAssertNil(history.first?.rightCenterTemp)
        let summary = try await client.summary(start: start, end: end)
        XCTAssertEqual(summary.bedTemp?.recordCount, 360)
        let flow = try await client.flow(hours: 168)
        XCTAssertEqual(flow.first?.value(side: .left, rpm: false), 24.12)
    }
}

private final class SensorTransportProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "sensors.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        XCTAssertEqual(request.httpMethod, "GET")
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let json: String
        switch url.path {
        case "/api/biometrics/occupancy":
            XCTAssertTrue(query.isEmpty)
            json = #"{"left":{"occupied":false,"available":false,"classification":"none","movement":{"active":false,"peakScore":0},"level":{"active":false,"deviation":null,"threshold":null,"ageMs":null,"zoneDeviations":null,"zones":null},"vitals":{"heartRate":null,"breathingRate":null,"humanRange":null}},"right":{"occupied":true,"available":true,"classification":"light","movement":{"active":true,"peakScore":42},"level":{"active":true,"deviation":12,"threshold":10,"ageMs":500,"zoneDeviations":[12,0,0],"zones":1},"vitals":{"heartRate":null,"breathingRate":null,"humanRange":null}}}"#
        case "/api/environment/bed-temp/latest":
            XCTAssertEqual(query, ["unit": "C"])
            json = #"{"timestamp":"2026-10-25T10:00:00Z","leftOuterTemp":21,"leftCenterTemp":null,"leftInnerTemp":23}"#
        case "/api/environment/freezer-temp/latest":
            XCTAssertEqual(query, ["unit": "C"])
            json = #"{"id":1,"timestamp":"2026-10-25T10:00:00.000Z","leftWaterTemp":21.45,"rightWaterTemp":null,"ambientTemp":24,"heatsinkTemp":null}"#
        case "/api/water-level/latest":
            XCTAssertTrue(query.isEmpty); json = "null"
        case "/api/environment/bed-temp":
            XCTAssertEqual(query, ["startDate": "1970-01-01T00:16:40Z", "endDate": "1970-01-01T06:16:40Z", "limit": "360", "unit": "C"])
            json = #"[{"timestamp":"2026-10-25T10:00:00Z","leftCenterTemp":22,"rightCenterTemp":null}]"#
        case "/api/environment/summary":
            XCTAssertEqual(query, ["startDate": "1970-01-01T00:16:40Z", "endDate": "1970-01-01T06:16:40Z", "unit": "C"])
            json = #"{"bedTemp":{"recordCount":360,"avgAmbientTemp":22,"minAmbientTemp":21,"maxAmbientTemp":23,"avgHumidity":45,"avgLeftCenterTemp":25,"avgRightCenterTemp":26},"freezerTemp":null}"#
        case "/api/water-level/flow":
            XCTAssertEqual(query, ["hours": "168"])
            json = #"[{"timestamp":"2026-10-25T10:00:00Z","leftFlowrateCd":2412,"rightFlowrateCd":null,"leftPumpRpm":2000,"rightPumpRpm":0}]"#
        default:
            XCTFail("Unexpected sensor route \(url.path)"); client?.urlProtocol(self, didFailWithError: APIError.noBaseURL); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
