import XCTest
@testable import Sleepypod

final class CoreConnectionTransportTests: XCTestCase {
    func testAuthenticationStatusSurvivesTRPCMessageEnvelope() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionStatusProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for code in [401, 403] {
            let client = SleepypodCoreClient(session: session, baseURL: URL(string: "https://status-\(code).connection.invalid")!)
            do { _ = try await client.getDeviceStatus(); XCTFail("Expected access rejection") }
            catch {
                guard case APIError.invalidResponse(let status) = error else { return XCTFail("Lost HTTP status: \(error)") }
                XCTAssertEqual(status, code)
                XCTAssertEqual(ConnectionIssue(error), .authentication)
            }
        }
    }
}

private final class ConnectionStatusProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".connection.invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(url.path, "/api/trpc/device.getStatus")
        let status = url.host?.contains("401") == true ? 401 : 403
        let body = Data(#"{"error":{"json":{"message":"Access rejected"}}}"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
