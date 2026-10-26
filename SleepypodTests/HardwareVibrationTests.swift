import XCTest
@testable import Sleepypod

@MainActor final class HardwareVibrationTests: XCTestCase {
    func testWebDurationsAndFixedFields() throws {
        XCTAssertEqual(HardwareVibrationPreset.allCases.compactMap(\.duration), [10, 30, 60])
        let request = HardwareVibrationRequest(side: .right, duration: 17)
        let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        XCTAssertEqual(fields?["side"] as? String, "right")
        XCTAssertEqual(fields?["duration"] as? Int, 17)
        XCTAssertEqual(fields?["vibrationIntensity"] as? Int, 100)
        XCTAssertEqual(fields?["vibrationPattern"] as? String, "rise")
        XCTAssertThrowsError(try HardwareVibrationRequest(side: .left, duration: 0).validate())
        XCTAssertThrowsError(try HardwareVibrationRequest(side: .left, duration: 61).validate())
    }
    func testInvalidOrRejectedPlayCannotClaimAnActiveTest() async {
        let client = VibrationFixtureClient(playAccepted: false)
        let model = HardwareVibrationWorkspace(client: client)
        await model.play(side: .left, duration: 100)
        var calls = await client.plays
        XCTAssertTrue(calls.isEmpty)
        await model.play(side: .left, duration: 10)
        calls = await client.plays
        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(model.active()); XCTAssertNil(model.notice)
        XCTAssertTrue(model.error?.contains("rejected") == true)
    }
    func testUnknownPlayRequiresStopAndPreservesOriginalSide() async {
        let client = VibrationFixtureClient(playFails: true)
        let model = HardwareVibrationWorkspace(client: client)
        await model.play(side: .right, duration: 10)
        XCTAssertEqual(model.uncertainSide, .right)
        XCTAssertNil(model.active())
        await model.play(side: .left, duration: 10)
        let plays = await client.plays
        XCTAssertEqual(plays.count, 1)
        await model.stop(selectedSide: .left)
        let stops = await client.stops
        XCTAssertEqual(stops, [.right]); XCTAssertNil(model.uncertainSide)
        XCTAssertEqual(model.notice, "Stop accepted for the right side.")
    }
    func testFailedStopStaysUnconfirmedUntilAccepted() async {
        let client = VibrationFixtureClient(stopAccepted: false)
        let model = HardwareVibrationWorkspace(client: client)
        await model.play(side: .left, duration: 60)
        await model.stop(selectedSide: .right)
        XCTAssertEqual(model.uncertainSide, .left)
        XCTAssertNotNil(model.active()); XCTAssertNil(model.notice)
        await client.acceptStop()
        await model.stop(selectedSide: .right)
        let stops = await client.stops
        XCTAssertEqual(stops, [.left, .left])
        XCTAssertNil(model.active()); XCTAssertNil(model.uncertainSide)
    }
    func testElapsedTimerNeverSendsCommandsAndActiveSideCannotChange() async {
        let client = VibrationFixtureClient()
        let model = HardwareVibrationWorkspace(client: client)
        await model.play(side: .left, duration: 10)
        let active = model.active()!
        XCTAssertEqual(active.progress(at: active.startedAt.addingTimeInterval(-1)), 0)
        XCTAssertEqual(active.progress(at: active.end.addingTimeInterval(1)), 1)
        XCTAssertNil(model.active(at: active.end))
        await model.play(side: .right, duration: 10, now: active.startedAt.addingTimeInterval(1))
        let plays = await client.plays, stops = await client.stops
        XCTAssertEqual(plays.count, 1); XCTAssertTrue(stops.isEmpty)
    }
    func testExactPlayAndClearRequests() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [VibrationFixtureProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let client = CoreHardwareVibrationClient(transport: .init(endpoint: URL(string: "https://vibration-test.invalid")!, session: session))
        let play = try await client.play(.init(side: .right, duration: 30))
        let stop = try await client.stop(.right)
        XCTAssertTrue(play); XCTAssertFalse(stop)
    }
}
private actor VibrationFixtureClient: HardwareVibrationClient {
    private let playAccepted: Bool
    private var stopAccepted: Bool
    private let playFails: Bool
    private(set) var plays: [HardwareVibrationRequest] = []
    private(set) var stops: [Side] = []
    init(playAccepted: Bool = true, stopAccepted: Bool = true, playFails: Bool = false) { self.playAccepted = playAccepted; self.stopAccepted = stopAccepted; self.playFails = playFails }
    func acceptStop() { stopAccepted = true }
    func play(_ request: HardwareVibrationRequest) throws -> Bool { plays.append(request); if playFails { throw APIError.noBaseURL }; return playAccepted }
    func stop(_ side: Side) -> Bool { stops.append(side); return stopAccepted }
}
private final class VibrationFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "vibration-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        do {
            XCTAssertEqual(request.httpMethod, "POST")
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
            let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let json: String
            switch url.path {
            case "/api/device/alarm":
                XCTAssertEqual(fields?.count, 4)
                XCTAssertEqual(fields?["side"] as? String, "right")
                XCTAssertEqual(fields?["duration"] as? Int, 30)
                XCTAssertEqual(fields?["vibrationIntensity"] as? Int, 100)
                XCTAssertEqual(fields?["vibrationPattern"] as? String, "rise")
                json = #"{"success":true}"#
            case "/api/device/alarm/clear":
                XCTAssertEqual(fields as? [String: String], ["side": "right"])
                json = #"{"success":false}"#
            default: XCTFail("Unexpected request \(url.path)"); throw APIError.noBaseURL
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
