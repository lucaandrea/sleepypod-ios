import XCTest
@testable import Sleepypod

@MainActor final class NightPhaseTransportTests: XCTestCase {
    func testUsesOnlyPublishedScheduleRESTAndRejectsUnacknowledgedBatch() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NightPhaseTransportProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        for host in ["night-success.invalid", "night-unconfirmed.invalid", "night-offline.invalid"] {
            let client = CoreNightPhaseClient(transport: .init(endpoint: URL(string: "https://\(host)")!, session: session))
            let rows = try await client.rows(side: .right); XCTAssertTrue(rows.temperature.isEmpty)
            var batch = NightPhaseBatch(); batch.updates.temperature = [.init(id: 41, temperature: 73)]
            do {
                try await client.apply(batch); XCTAssertEqual(host, "night-success.invalid")
            } catch { XCTAssertNotEqual(host, "night-success.invalid") }
        }
    }
}
private final class NightPhaseTransportProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasPrefix("night-") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        var status = 200, body = "{\"temperature\":[],\"power\":[],\"alarm\":[]}"
        if url.path == "/api/schedules" {
            XCTAssertEqual(request.httpMethod, "GET")
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query, ["side": "right", "unit": "F"])
        } else if url.path == "/api/schedules/batch" {
            XCTAssertEqual(request.httpMethod, "POST")
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
            }
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let updates = object?["updates"] as? [String: Any]
            XCTAssertEqual(updates?["temperature"] as? NSArray, [["id": 41, "temperature": 73]] as NSArray)
            XCTAssertEqual(updates?["alarm"] as? [Int], []); XCTAssertEqual(updates?["power"] as? [Int], [])
            if url.host == "night-offline.invalid" { status = 503; body = "{\"message\":\"Example controller unavailable\"}" }
            else { body = "{\"success\":\(url.host == "night-success.invalid" ? "true" : "false")}" }
        } else { XCTFail("Unexpected phase endpoint: \(url.path)") }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
