import XCTest
@testable import Sleepypod

final class DevicePreferencesTransportTests: XCTestCase {
    func testReadPartialPatchAndReadOnlySensorSourceRoutes() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DevicePreferenceProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = CoreDevicePreferencesClient(transport: CoreRESTClient(endpoint: URL(string: "https://device-preferences.invalid")!, session: session))
        let original = try await client.settings()
        XCTAssertEqual(original.globalMaxOnHours, 12)
        var changed = original; changed.globalMaxOnHours = nil; changed.ledDayBrightness = 42
        try await client.save(changed.patch(from: original))
        let source = try await client.sensorSource()
        XCTAssertEqual(source.sourceLabel, "NATS stream")
        XCTAssertEqual(source.status(), "Live")
        let restart = try await client.restart()
        XCTAssertTrue(restart.ok); XCTAssertEqual(restart.message, "Restart requested")
    }
    func testClientRefusesUnknownPreferenceKeysBeforeNetwork() async {
        let client = CoreDevicePreferencesClient(transport: nil)
        do { try await client.save(.init(fields: ["homekitEnabled": .boolean(true)])); XCTFail("Unexpected save") }
        catch { XCTAssertTrue(error.localizedDescription.contains("supported device")) }
    }
}
private final class DevicePreferenceProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "device-preferences.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        do {
            let data: Data
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/settings"):
                data = Data(#"{"device":{"timezone":"Europe/Paris","temperatureUnit":"C","timeFormat":"24h","defaultScheduleEndAction":"maintain","globalMaxOnHours":12,"rebootDaily":false,"rebootTime":null,"primePodDaily":true,"primePodTime":"14:00","ledNightModeEnabled":true,"ledDayBrightness":80,"ledNightBrightness":5,"ledNightStartTime":"22:00","ledNightEndTime":"07:00","homekitEnabled":true},"sides":{},"gestures":{}}"#.utf8)
            case ("PATCH", "/api/settings/device"):
                let body = try requestBody()
                XCTAssertEqual(Set(body.keys), ["globalMaxOnHours", "ledDayBrightness"])
                XCTAssertTrue(body["globalMaxOnHours"] is NSNull)
                XCTAssertEqual(body["ledDayBrightness"] as? Int, 42)
                // The real PATCH response omits the power cap; the workspace must read it again.
                data = Data(#"{"id":1,"timezone":"Europe/Paris","ledDayBrightness":42}"#.utf8)
            case ("GET", "/api/system/sensor-source"):
                data = Data(#"{"firmware":{"label":"NATS firmware","detail":"fixture","expectedTransport":"nats","probed":true},"stream":{"source":"nats","override":null,"legacyNatsDisabled":false,"lastFrameAgeMs":1200,"lastFrameType":"capSense2","uptimeSeconds":800}}"#.utf8)
            case ("POST", "/api/health/restart-service"):
                let body = try requestBody()
                XCTAssertEqual(body.count, 1); XCTAssertEqual(body["unit"] as? String, "sleepypod.service")
                data = Data(#"{"ok":true,"message":"Restart requested"}"#.utf8)
            default: XCTFail("Unexpected device preferences route \(url.path)"); throw APIError.invalidResponse(statusCode: 404)
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    private func requestBody() throws -> [String: Any] {
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
        return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
