import XCTest
@testable import Sleepypod

final class SleeperGestureTransportTests: XCTestCase {
    func testExactRESTAndTRPCContracts() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SleeperGestureProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let transport = CoreRESTClient(endpoint: URL(string: "https://sleeper-gestures.invalid")!, session: session)
        let sides = CoreSleeperPreferencesClient(transport: transport)
        let snapshot = try await sides.settings(); XCTAssertEqual(snapshot.sides.left.name, "Alex"); XCTAssertEqual(snapshot.device.timeFormat, "24h")
        let presence = try await sides.occupancy(); XCTAssertTrue(presence.left.available); XCTAssertFalse(presence.right.available)
        try await sides.saveBed(.init(fields: ["bedMode": .string("solo-left"), "unusedZoneMode": .string("follow")]))
        try await sides.saveSide(.right, patch: .init(fields: ["awayReturn": .null, "alwaysOn": .boolean(true), "autoOffEnabled": .boolean(false)]))
        let gestures = CoreGestureBindingsClient(transport: transport)
        let mapping = try await gestures.settings(); XCTAssertTrue(mapping.gestures.left.isEmpty)
        var draft = GestureDraft(side: .right, tap: .tripleTap, original: nil)
        draft.temperatureChange = "decrement"; draft.temperatureAmount = 3
        try await gestures.save(draft)
        draft.actionType = "alarm"; draft.alarmBehavior = "snooze"; draft.alarmInactiveBehavior = "power"; draft.alarmSnoozeDuration = 90
        try await gestures.save(draft)
        try await gestures.remove(side: .right, tap: .tripleTap)
    }
    func testUnrelatedKeysAndInvalidGestureNeverReachTransport() async {
        let sides = CoreSleeperPreferencesClient(transport: nil)
        do { try await sides.saveBed(.init(fields: ["timezone": .string("UTC")])); XCTFail("Unexpected write") } catch { XCTAssertTrue(error.localizedDescription.contains("Unsupported bed")) }
        do { try await sides.saveSide(.left, patch: .init(fields: ["awayStart": .null])); XCTFail("Unexpected write") } catch { XCTAssertTrue(error.localizedDescription.contains("Unsupported sleeper")) }
        var draft = GestureDraft(side: .left, tap: .doubleTap, original: nil); draft.temperatureAmount = 11
        do { try await CoreGestureBindingsClient(transport: nil).save(draft); XCTFail("Unexpected write") } catch { XCTAssertTrue(error.localizedDescription.contains("0–10")) }
    }
}
private final class SleeperGestureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "sleeper-gestures.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        do {
            var reply = #"{}"#
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/settings"):
                reply = #"{"device":{"bedMode":"two","unusedZoneMode":"off","timezone":"Europe/Paris","timeFormat":"24h","ledDayBrightness":80},"sides":{"left":{"side":"left","name":"Alex","awayMode":false,"awayStart":null,"awayReturn":null,"alwaysOn":false,"autoOffEnabled":false,"autoOffMinutes":30,"autoOnEnabled":false,"autoOnMinutes":5,"autoOnStart":"20:00","autoOnEnd":"08:00"},"right":{"side":"right","name":"Sam","awayMode":true,"awayStart":null,"awayReturn":"2026-11-02T12:00:00Z","alwaysOn":false,"autoOffEnabled":true,"autoOffMinutes":20,"autoOnEnabled":false,"autoOnMinutes":2,"autoOnStart":"00:00","autoOnEnd":"00:00"}},"gestures":{"left":[],"right":[]}}"#
            case ("GET", "/api/biometrics/occupancy"):
                reply = #"{"left":{"occupied":true,"available":true,"classification":"human","movement":{"active":false,"peakScore":0},"level":{"active":true,"ageMs":800},"vitals":{}},"right":{"occupied":false,"available":false,"classification":"unknown","movement":{"active":false,"peakScore":0},"level":{"active":false},"vitals":{}}}"#
            case ("PATCH", "/api/settings/device"):
                let body = try body(); XCTAssertEqual(Set(body.keys), ["bedMode", "unusedZoneMode"])
                XCTAssertEqual(body["bedMode"] as? String, "solo-left"); XCTAssertEqual(body["unusedZoneMode"] as? String, "follow")
            case ("PATCH", "/api/settings/side"):
                let body = try body(); XCTAssertEqual(Set(body.keys), ["side", "awayReturn", "alwaysOn", "autoOffEnabled"])
                XCTAssertEqual(body["side"] as? String, "right"); XCTAssertTrue(body["awayReturn"] is NSNull)
                XCTAssertEqual(body["alwaysOn"] as? Bool, true); XCTAssertEqual(body["autoOffEnabled"] as? Bool, false)
            case ("POST", "/api/trpc/settings.setGesture"):
                let envelope = try body(); XCTAssertEqual(Set(envelope.keys), ["json"])
                let input = try XCTUnwrap(envelope["json"] as? [String: Any])
                XCTAssertEqual(input["side"] as? String, "right"); XCTAssertEqual(input["tapType"] as? String, "tripleTap")
                if input["actionType"] as? String == "temperature" {
                    XCTAssertEqual(Set(input.keys), ["side", "tapType", "actionType", "temperatureChange", "temperatureAmount"])
                    XCTAssertEqual(input["temperatureChange"] as? String, "decrement"); XCTAssertEqual(input["temperatureAmount"] as? Int, 3)
                } else {
                    XCTAssertEqual(Set(input.keys), ["side", "tapType", "actionType", "alarmBehavior", "alarmInactiveBehavior", "alarmSnoozeDuration"])
                    XCTAssertEqual(input["alarmSnoozeDuration"] as? Int, 90); XCTAssertEqual(input["alarmInactiveBehavior"] as? String, "power")
                }
                reply = #"{"result":{"data":{"json":{"id":4,"side":"right","tapType":"tripleTap","actionType":"alarm","temperatureChange":null,"temperatureAmount":null,"alarmBehavior":"snooze","alarmSnoozeDuration":90,"alarmInactiveBehavior":"power"},"meta":{"values":{"updatedAt":["Date"]}}}}}"#
            case ("DELETE", "/api/settings/gesture"):
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertEqual(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }), ["side": "right", "tapType": "tripleTap"])
                reply = #"{"success":true}"#
            default: XCTFail("Unexpected settings route \(url.path)"); throw URLError(.unsupportedURL)
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    private func body() throws -> [String: Any] {
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
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
