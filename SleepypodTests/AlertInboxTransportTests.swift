import XCTest
@testable import Sleepypod

@MainActor final class AlertInboxTransportTests: XCTestCase {
    func testExactAuthenticatedTransportRoutesPaginationAndSelectedIds() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AlertContractProtocol.self]
        let client = CoreAlertInboxClient(transport: .init(endpoint: URL(string: "https://alerts-contract.invalid")!, session: URLSession(configuration: configuration)))
        let latest = try await client.page(before: nil); XCTAssertEqual(latest.items.map(\.id), [11])
        let older = try await client.page(before: 11); XCTAssertEqual(older.items.map(\.id), [10])
        let receipt = try await client.acknowledge([10]); XCTAssertEqual(receipt.acknowledgedIds, [10])
        do { _ = try await client.acknowledge([]); XCTFail("Empty acknowledgment must be rejected") } catch {}
    }
}
private final class AlertContractProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "alerts-contract.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url)
            let response: [String: Any]
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/v1/notifications"):
                let identifier = url.query == nil ? 11 : 10
                if url.query != nil { XCTAssertEqual(url.query, "beforeId=11") }
                response = ["apiVersion": 1, "generatedAt": 100000, "newestId": 11, "nextBeforeId": url.query == nil ? 11 : NSNull(), "unreadCount": 2,
                            "delivery": ["foregroundInbox": true, "backgroundPush": false],
                            "items": [["id": identifier, "source": "automation", "sourceId": 2, "title": "Synthetic alert", "message": "Literal <message>",
                                       "createdAt": 99000, "expiresAt": 999000, "acknowledgedAt": NSNull()]]]
            case ("POST", "/api/v1/notifications/acknowledge"):
                let payload = try body(); XCTAssertEqual(Set(payload.keys), ["ids"]); XCTAssertEqual(payload["ids"] as? [Int], [10]); XCTAssertNil(url.query)
                response = ["generatedAt": 100001, "acknowledgedIds": [10], "missingIds": []]
            default: XCTFail("Unexpected alert request \(request)"); throw APIError.invalidResponse(statusCode: 400)
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: response)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func body() throws -> [String: Any] {
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(buffer, count: count) }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    override func stopLoading() {}
}
