import XCTest
@testable import Sleepypod

@MainActor final class ControllerUpdateTransportTests: XCTestCase {
    func testExactRoutesAndInstalledRepositoryCapability() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [UpdateContractProtocol.self]
        let client = CoreControllerUpdateClient(transport: .init(endpoint: URL(string: "https://update-contract.invalid")!, session: URLSession(configuration: configuration)))
        let snapshot = try await client.snapshot()
        XCTAssertTrue(snapshot.preservesInstalledRepository); XCTAssertTrue(snapshot.internetBlocked)
        XCTAssertEqual(snapshot.build.branch, "main")
        let receipt = try await client.trigger(channel: .dev)
        XCTAssertEqual(receipt.branch, "dev"); XCTAssertEqual(receipt.repository, "synthetic/owner-fork")
        let blocked = try await client.blockInternet(); XCTAssertTrue(blocked)
    }
    func testResponseCapabilityFollowsBoundedReferencesAndRejectsRequestOnlyClaim() throws {
        let json = ##"{"paths":{"/system/update":{"post":{"responses":{"200":{"content":{"application/json":{"schema":{"$ref":"#/components/schemas/Receipt"}}}}},"requestBody":{"content":{"application/json":{"schema":{"properties":{"repository":{}}}}}}}}},"components":{"schemas":{"Receipt":{"allOf":[{"properties":{"repository":{}}}]}}}}"##
        let schema = try JSONDecoder().decode(CoreAPIDocument.self, from: Data(json.utf8))
        XCTAssertTrue(schema.returns("repository", path: "/system/update", method: "post"))
        let old = ##"{"paths":{"/system/update":{"post":{"requestBody":{"content":{"application/json":{"schema":{"properties":{"repository":{}}}}}}}}}}"##
        XCTAssertFalse(try JSONDecoder().decode(CoreAPIDocument.self, from: Data(old.utf8)).returns("repository", path: "/system/update", method: "post"))
    }
}
private final class UpdateContractProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "update-contract.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url)
            let response: Any
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/openapi.json"):
                response = ["paths": ["/system/update": ["post": ["responses": ["200": ["content": ["application/json": ["schema": ["properties": ["repository": ["type": "string"]]]]]]]]]]]
            case ("GET", "/api/system/version"):
                response = ["branch": "main", "commitHash": "synthetic", "commitTitle": "Synthetic", "buildDate": "2026-10-26T00:00:00Z", "version": NSNull()] as [String: Any]
            case ("GET", "/api/system/internet-status"): response = ["blocked": true]
            case ("POST", "/api/system/update"):
                let body = try body(); XCTAssertEqual(Set(body.keys), ["branch"]); XCTAssertEqual(body["branch"] as? String, "dev")
                response = ["triggered": true, "branch": "dev", "repository": "synthetic/owner-fork", "message": "Synthetic dispatch"] as [String: Any]
            case ("POST", "/api/system/internet-access"):
                let body = try body(); XCTAssertEqual(Set(body.keys), ["blocked"]); XCTAssertEqual(body["blocked"] as? Bool, true)
                response = ["blocked": true]
            default: XCTFail("Unexpected update request \(request)"); throw APIError.invalidResponse(statusCode: 400)
            }
            XCTAssertNil(url.query)
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
