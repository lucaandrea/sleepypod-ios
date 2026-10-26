import XCTest
@testable import Sleepypod

@MainActor final class HomeRoomTransportTests: XCTestCase {
    func testExactVersionedStatusSaveHistoryAndPublisherContracts() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RoomContractProtocol.self]
        let client = CoreHomeRoomClient(transport: .init(endpoint: URL(string: "https://room-contract.invalid")!, session: URLSession(configuration: configuration)))
        let status = try await client.status(); XCTAssertEqual(status.revision, 7); XCTAssertEqual(status.observations.count, 3)
        let saved = try await client.configure(status.config, expectedRevision: status.revision); XCTAssertEqual(saved.revision, 8)
        let history = try await client.history(before: 11); XCTAssertEqual(history.items.count, 3)
        let publishers = try await client.publishers(); XCTAssertEqual(publishers.automations.count, 3)
    }
}
private final class RoomContractProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "room-contract.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url)
            let fixtureURL = try XCTUnwrap(Bundle.main.url(forResource: "room-context-core", withExtension: "json"))
            let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
            let response: Any
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/v1/home/context"): response = try XCTUnwrap(fixture["status"]); XCTAssertNil(url.query)
            case ("PUT", "/api/v1/home/context/configuration"):
                let payload = try body(); XCTAssertEqual(Set(payload.keys), ["expectedRevision", "config"]); XCTAssertEqual(payload["expectedRevision"] as? Int, 7)
                let config = try XCTUnwrap(payload["config"] as? [String: Any]); XCTAssertEqual(Set(config.keys), ["enabled", "roomName", "mappings"])
                let mappings = try XCTUnwrap(config["mappings"] as? [[String: Any]])
                XCTAssertEqual(Set(mappings[0].keys), ["metric", "entityId", "unit", "timestampAttribute", "timestampFormat", "maxAgeSeconds"])
                XCTAssertEqual(mappings[0]["unit"] as? String, "°C"); XCTAssertNil(url.query)
                response = ["revision": 8, "config": config]
            case ("GET", "/api/v1/home/context/history"): response = try XCTUnwrap(fixture["history"]); XCTAssertEqual(url.query, "beforeId=11")
            case ("GET", "/api/v1/home/context/publisher"): response = try XCTUnwrap(fixture["publishers"]); XCTAssertNil(url.query)
            default: XCTFail("Unexpected room request \(request)"); throw APIError.invalidResponse(statusCode: 400)
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
