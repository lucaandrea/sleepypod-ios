import XCTest
@testable import Sleepypod

@MainActor final class NextAlarmRESTTests: XCTestCase {
    private func client(_ host: String, now: Date = .now) -> (CoreNextAlarmClient, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [NextAlarmRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        return (.init(transport: .init(endpoint: URL(string: "https://\(host)")!, session: session), now: { now }), session)
    }
    func testLaterWakeUsesAdvertisedFixedRoutesAndEchoesTheExactReviewedObject() async throws {
        let fixture = try LaterWakeTestFixture()
        let (client, session) = client("later-contract.invalid", now: fixture.now); defer { session.invalidateAndCancel() }
        try await client.laterAvailable()
        let packet = try await client.previewLater(fixture.input)
        let saved = try await client.applyLater(packet)
        XCTAssertEqual(saved, fixture.saved)
    }
    func testLaterWakeRejectsUnsupportedCapabilityAndInconsistentPreview() async throws {
        let fixture = try LaterWakeTestFixture()
        for host in ["later-unsupported.invalid", "later-invalid.invalid"] {
            let (client, session) = client(host, now: fixture.now); defer { session.invalidateAndCancel() }
            do {
                if host.contains("unsupported") { try await client.laterAvailable() }
                else { _ = try await client.previewLater(fixture.input) }
                XCTFail("Unverified later-wake source must be rejected")
            } catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE")) }
        }
    }
    func testContractFixedRoutesQueryAndExactActionBodies() async throws {
        let (client, session) = client("alarm-contract.invalid"); defer { session.invalidateAndCancel() }
        try await client.available(); let current = try await client.read(side: .left)
        let skipped = try await client.write(.init(base: current, action: "skip")); XCTAssertEqual(skipped.state, "skipped")
        let restored = try await client.write(.init(base: skipped, action: "restore")); XCTAssertEqual(restored.state, "scheduled")
        let changed = try await client.write(.init(base: restored, action: "time", time: "08:00"))
        XCTAssertEqual(changed.alarm?.time, "08:00"); XCTAssertEqual(changed.schedulerUpdated, false)
    }
    func testConflictErrorsAndUnsupportedEndpointDoNotRedirectOrExposeBodies() async throws {
        for host in ["alarm-conflict.invalid", "alarm-key.invalid", "alarm-zone.invalid", "alarm-time.invalid", "alarm-failed.invalid", "alarm-unsupported.invalid"] {
            let (client, session) = client(host); defer { session.invalidateAndCancel() }
            do { if host.contains("unsupported") { try await client.available() } else { _ = try await client.read(side: .left) }; XCTFail("Request should fail") }
            catch {
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE"))
                if host.contains("conflict") { XCTAssertEqual(error as? NextAlarmFailure, .conflict) }
                if host.contains("unsupported") { XCTAssertTrue(error.localizedDescription.contains("Update")) }
            }
        }
    }
    func testWrongSideMalformedStateAndMissingWriteReceiptAreRejected() async throws {
        for host in ["alarm-side.invalid", "alarm-invalid.invalid"] {
            let (client, session) = client(host); defer { session.invalidateAndCancel() }
            do { _ = try await client.read(side: .left); XCTFail("Reject inconsistent read") } catch { XCTAssertEqual(error as? NextAlarmFailure, .invalid) }
        }
        let (client, session) = client("alarm-no-receipt.invalid"); defer { session.invalidateAndCancel() }
        let base = try XCTUnwrap(NextAlarmExample.load().cases["scheduled"])
        do { _ = try await client.write(.init(base: base, action: "skip")); XCTFail("Write needs a scheduler receipt") } catch { XCTAssertEqual(error as? NextAlarmFailure, .invalid) }
    }
}
private final class NextAlarmRequestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = request.url!, host = url.host!, examples = try NextAlarmExample.load().cases
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            var valid = request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData, status = 200
            var payload: [String: Any]
            if let code = ["alarm-conflict.invalid": 409, "alarm-key.invalid": 401, "alarm-zone.invalid": 412, "alarm-time.invalid": 400, "alarm-failed.invalid": 503][host] {
                status = code; payload = ["message": "PRIVATE response data"]
            } else if url.path == "/api/v1/capabilities" {
                valid = valid && request.httpMethod == "GET" && query.isEmpty
                payload = ["apiVersion": 1, "features": ["nextAlarmOverride": ["implemented": true, "runtime": "ready"], "laterAlarmPreview": ["implemented": true, "runtime": "ready"]],
                    "endpoints": ["nextAlarm": host.contains("unsupported") ? "https://external.invalid/next" : "/api/v1/alarm/next", "alarmOverride": "/api/v1/alarm/override",
                        "laterAlarmPreview": host.contains("unsupported") ? "https://external.invalid/preview" : "/api/v1/alarm/later-preview", "laterAlarmApply": "/api/v1/alarm/later-apply"]]
            } else if url.path == "/api/v1/alarm/later-preview", request.httpMethod == "POST" {
                let fixture = try LaterWakeTestFixture()
                let input = try JSONDecoder().decode(LaterWakeRequest.self, from: body())
                valid = valid && query.isEmpty && input == fixture.input
                payload = try JSONSerialization.jsonObject(with: fixture.previewData) as! [String: Any]
                if host == "later-invalid.invalid" { payload["weeklyScheduleChanged"] = true }
            } else if url.path == "/api/v1/alarm/later-apply", request.httpMethod == "POST" {
                let fixture = try LaterWakeTestFixture(), fields = try JSONSerialization.jsonObject(with: body()) as! [String: Any]
                let expected = try JSONSerialization.jsonObject(with: fixture.previewData) as! NSDictionary
                let received = fields["preview"] as? NSDictionary
                valid = valid && query.isEmpty && Set(fields.keys) == ["preview"] && expected == received
                payload = try object(fixture.saved)
            } else if url.path == "/api/v1/alarm/next", request.httpMethod == "GET" {
                valid = valid && query == ["side": "left"]
                payload = try object(examples["scheduled"]!)
                if host.contains("side") { payload["side"] = "right" }
                if host.contains("invalid") && host == "alarm-invalid.invalid" { payload["revision"] = "bad revision" }
            } else if url.path == "/api/v1/alarm/override", request.httpMethod == "POST" {
                let fields = try JSONSerialization.jsonObject(with: body()) as! [String: Any], action = fields["action"] as? String ?? ""
                let base = examples[action == "restore" ? "skipped" : action == "time" ? "restored" : "scheduled"]!
                let expected = try NextAlarmWrite(base: base, action: action, time: action == "time" ? "08:00" : nil)
                let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as! NSDictionary
                valid = valid && query.isEmpty && encoded.isEqual(to: fields)
                payload = try object(examples[action == "restore" ? "restored" : action == "time" ? "changed" : "skipped"]!)
                if !host.contains("no-receipt") { payload["schedulerUpdated"] = false }
            } else { valid = false; payload = [:] }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: valid ? status : 422, httpVersion: nil, headerFields: ["Cache-Control": "private, no-store"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: payload)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func object(_ value: NextAlarmState) throws -> [String: Any] { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any] }
    private func body() throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { throw NextAlarmFailure.invalid }
        stream.open(); defer { stream.close() }; var data = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); guard count >= 0 else { throw NextAlarmFailure.invalid }; if count == 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
        return data
    }
    override func stopLoading() {}
}
