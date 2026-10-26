import XCTest
@testable import Sleepypod

final class BridgeSettingsTransportTests: XCTestCase {
    func testExactHomeKitAndMQTTRoutesAndSecretOmission() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BridgeSettingsFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = CoreRESTClient(endpoint: URL(string: "https://bridge-settings-test.invalid")!, session: session)
        let homekit = CoreHomeKitBridgeClient(transport: transport), mqtt = CoreMQTTSettingsClient(transport: transport)
        let bridge = try await homekit.status()
        XCTAssertEqual(bridge.pairedControllers.count, 1)
        let disabled = try await homekit.setEnabled(false)
        XCTAssertFalse(disabled.enabled)
        let pairing = try await homekit.resetPairing()
        XCTAssertEqual(pairing.formattedCode, "031-45-154")
        let settings = try await mqtt.settings()
        XCTAssertTrue(settings.passwordIsSet)
        XCTAssertEqual(settings.sourceLabel("password"), "Pod environment")
        let status = try await mqtt.status()
        XCTAssertFalse(status.commandsEnabled ?? true)
        try await mqtt.save(.init(topicPrefix: "fixture/bedroom"))
        let result = try await mqtt.test(.init(url: "mqtts://broker.example.invalid:8883", username: "fixture", password: nil, tlsEnabled: true))
        XCTAssertTrue(result.ok)
    }
}

private final class BridgeSettingsFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "bridge-settings-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        do {
            let body = try requestBody()
            let json: String
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/homekit/status"):
                json = #"{"enabled":true,"running":true,"transitioning":false,"pincode":null,"setupId":null,"setupURI":null,"qrDataUrl":null,"pairedControllers":["Fixture home"]}"#
            case ("POST", "/api/homekit/enabled"):
                XCTAssertEqual(body["enabled"] as? Bool, false); XCTAssertEqual(body.count, 1)
                json = #"{"enabled":false,"running":false,"transitioning":false,"pincode":null,"setupId":null,"setupURI":null,"qrDataUrl":null,"pairedControllers":["Fixture home"]}"#
            case ("POST", "/api/homekit/unpair"):
                XCTAssertTrue(body.isEmpty)
                json = #"{"enabled":true,"running":true,"transitioning":false,"pincode":"03145154","setupId":"TEST","setupURI":null,"qrDataUrl":null,"pairedControllers":[]}"#
            case ("GET", "/api/mqtt/settings"):
                json = #"{"enabled":true,"url":"mqtts://broker.example.invalid:8883","username":"fixture","passwordIsSet":true,"topicPrefix":"sleepypod","haDiscovery":true,"tlsEnabled":true,"sources":{"enabled":"db","url":"env","username":"env","password":"env","topicPrefix":"default","haDiscovery":"default","tlsEnabled":"db"}}"#
            case ("PATCH", "/api/mqtt/settings"):
                XCTAssertEqual(body["topicPrefix"] as? String, "fixture/bedroom"); XCTAssertEqual(body.count, 1)
                XCTAssertNil(body["password"]); XCTAssertNil(body["enabled"])
                json = #"{"success":true}"#
            case ("GET", "/api/mqtt/status"):
                json = #"{"runState":"connected","connected":true,"commandsEnabled":false,"lastError":null,"deviceId":"fixture","topicPrefix":"sleepypod","messagesPublished":10,"lastPublishAt":null}"#
            case ("POST", "/api/mqtt/test-connection"):
                XCTAssertEqual(body["url"] as? String, "mqtts://broker.example.invalid:8883")
                XCTAssertEqual(body["username"] as? String, "fixture")
                XCTAssertEqual(body["tlsEnabled"] as? Bool, true); XCTAssertNil(body["password"])
                XCTAssertEqual(body.count, 3)
                json = #"{"ok":true}"#
            default: XCTFail("Unexpected bridge route: \(url.path)"); throw APIError.invalidResponse(statusCode: 404)
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
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
