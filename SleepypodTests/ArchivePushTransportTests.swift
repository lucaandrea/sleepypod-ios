import XCTest
@testable import Sleepypod

final class ArchivePushTransportTests: XCTestCase {
    func testArchiveRoutesPreserveIdentityAndUseSavedTargetForTest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArchivePushFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = CoreArchivePushClient(transport: CoreRESTClient(endpoint: URL(string: "https://archive-contract.invalid")!, session: session))
        let snapshot = try await client.settings()
        XCTAssertNil(snapshot.publicKey)
        var saved = snapshot.config
        saved.enabled = true; saved.remotePath = "/owner/archive"
        try await client.save(saved)
        let key = try await client.generateKey()
        XCTAssertTrue(key.generated)
        let result = try await client.test()
        XCTAssertTrue(result.ok)
    }
}
private final class ArchivePushFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "archive-contract.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        do {
            let body = try requestBody()
            let json: String
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/archive-push/config"):
                json = #"{"config":{"enabled":false,"host":"storage.example.invalid","remoteUser":"fixture","remotePath":"/old/path","port":2222,"identity":"/custom/pod-identity","include":["raw","db"]},"publicKey":null}"#
            case ("POST", "/api/archive-push/config"):
                XCTAssertEqual(body.count, 7)
                XCTAssertEqual(body["enabled"] as? Bool, true)
                XCTAssertEqual(body["host"] as? String, "storage.example.invalid")
                XCTAssertEqual(body["remoteUser"] as? String, "fixture")
                XCTAssertEqual(body["remotePath"] as? String, "/owner/archive")
                XCTAssertEqual(body["port"] as? Int, 2222)
                XCTAssertEqual(body["identity"] as? String, "/custom/pod-identity")
                XCTAssertEqual(body["include"] as? [String], ["raw", "db"])
                XCTAssertNil(body["privateKey"])
                json = #"{"ok":true}"#
            case ("POST", "/api/archive-push/key"):
                XCTAssertTrue(body.isEmpty)
                json = #"{"publicKey":"synthetic-public-key","generated":true}"#
            case ("POST", "/api/archive-push/test"):
                XCTAssertTrue(body.isEmpty)
                json = #"{"ok":true,"message":"fixture accepted"}"#
            default: XCTFail("Unexpected archive route: \(url.path)"); throw APIError.invalidResponse(statusCode: 404)
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
