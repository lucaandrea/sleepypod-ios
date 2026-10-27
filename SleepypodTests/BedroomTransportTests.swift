import XCTest
@testable import Sleepypod

@MainActor final class BedroomTransportTests: XCTestCase {
    func testVersionedStatusAndCompareAndSwapConfigurationContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BedroomContractProtocol.self]
        let client = CoreBedroomClient(transport: .init(endpoint: URL(string: "https://bedroom-contract.invalid")!, session: URLSession(configuration: configuration)))
        let status = try await client.status()
        XCTAssertEqual(status.revision, 1); XCTAssertEqual(status.observations.count, 7)
        let result = try await client.configure(status.config, expectedRevision: status.revision)
        XCTAssertEqual(result.revision, 2); XCTAssertEqual(result.config, status.config)
    }
}

private final class BedroomContractProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "bedroom-contract.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url)
            XCTAssertNil(url.query)
            let fixture = try XCTUnwrap(Bundle.main.url(forResource: "bedroom-context-core", withExtension: "json"))
            let status = try JSONDecoder().decode(BedroomStatus.self, from: Data(contentsOf: fixture))
            let response: Data
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/v1/home/bedroom"): response = try JSONEncoder().encode(status)
            case ("PUT", "/api/v1/home/bedroom/configuration"):
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        data.append(buffer, count: count)
                    }
                }
                struct Request: Decodable { let expectedRevision: Int64; let config: BedroomConfiguration }
                let body = try JSONDecoder().decode(Request.self, from: data)
                XCTAssertEqual(body.expectedRevision, 1); XCTAssertEqual(body.config, status.config)
                response = try JSONEncoder().encode(BedroomVersion(revision: 2, config: body.config))
            default: throw APIError.invalidResponse(statusCode: 400)
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json", "Cache-Control": "no-store"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
