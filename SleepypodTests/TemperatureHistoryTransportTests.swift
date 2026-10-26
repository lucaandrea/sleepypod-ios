import XCTest
@testable import Sleepypod

@MainActor final class TemperatureHistoryTransportTests: XCTestCase {
    func testExactReadRoutesAndIndependentSourceFailures() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HistoryTransportProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let start = ISO8601DateFormatter().date(from: "2026-10-25T01:00:00Z")!
        let end = ISO8601DateFormatter().date(from: "2026-10-25T16:00:00Z")!
        for host in ["history-complete.invalid", "history-partial.invalid", "history-invalid.invalid"] {
            let client = CoreTemperatureHistoryClient(transport: .init(endpoint: URL(string: "https://\(host)")!, session: session))
            let result = await client.load(from: start, to: end)
            XCTAssertEqual(result.records[.right]?.value?.count, 1)
            XCTAssertNil(result.sessions[.left]?.error)
            if host == "history-partial.invalid" { XCTAssertNotNil(result.records[.left]?.error) }
            else { XCTAssertEqual(result.records[.left]?.value?.count, 1) }
            if host == "history-invalid.invalid" { XCTAssertNotNil(result.thermal.error); XCTAssertNotNil(result.sessions[.right]?.error) }
            else { XCTAssertNotNil(result.thermal.value); XCTAssertNil(result.sessions[.right]?.value) }
        }
    }
}
private final class HistoryTransportProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasPrefix("history-") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        XCTAssertEqual(request.httpMethod, "GET")
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let host = url.host ?? ""
        var status = 200, body = "null"
        switch url.path {
        case "/api/health/thermal-history":
            XCTAssertEqual(query, ["range": "24h"])
            body = "{\"range\":\"\(host == "history-invalid.invalid" ? "7d" : "24h")\",\"from\":1792890000000,\"to\":1792944000000,\"bucketSec\":60,\"points\":[],\"powerOn\":[],\"available\":{}}"
        case "/api/biometrics/sleep-records":
            XCTAssertEqual(query.count, 4); XCTAssertEqual(query["startDate"], "2026-10-25T01:00:00Z"); XCTAssertEqual(query["endDate"], "2026-10-25T16:00:00Z"); XCTAssertEqual(query["limit"], "100")
            let side = query["side"] ?? ""
            XCTAssertTrue(["left", "right"].contains(side))
            if side == "left" && host == "history-partial.invalid" { status = 503; body = "{\"message\":\"Example source unavailable\"}" }
            else { body = "[{\"id\":1,\"side\":\"\(side)\",\"enteredBedAt\":\"2026-10-25T05:00:00Z\",\"leftBedAt\":\"2026-10-25T13:00:00Z\",\"presentIntervals\":[[1792904400,1792933200]]}]" }
        case "/api/run-once/active":
            XCTAssertEqual(query.count, 1); XCTAssertTrue(["left", "right"].contains(query["side"] ?? ""))
            if query["side"] == "right" && host == "history-invalid.invalid" {
                body = "{\"id\":1,\"side\":\"left\",\"setPoints\":[{\"time\":\"22:00\",\"temperature\":68}],\"wakeTime\":\"07:00\",\"startedAt\":1792904400,\"expiresAt\":1792933200,\"status\":\"active\"}"
            }
        default: XCTFail("Unexpected history request: \(url.path)")
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
