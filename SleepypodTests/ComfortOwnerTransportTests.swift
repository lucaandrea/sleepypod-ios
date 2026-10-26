import XCTest
@testable import Sleepypod

@MainActor final class ComfortOwnerTransportTests: XCTestCase {
    func testExactOwnerRoutesSideReviewReferenceAndNullKind() async throws {
        let transport = transport("owner-contract.invalid"); defer { transport.session.invalidateAndCancel() }
        let client = CoreComfortOwnerClient(transport: transport)
        let status = try await client.status(side: .left); try status.validate(side: .left)
        let input = ComfortOwnerPrepare(side: .left, purpose: .activation, kind: nil)
        let review = try await client.prepare(input); try review.validate(for: input)
        let receipt = try await client.confirm(.init(side: .left, id: review.id, confirmed: true, note: "Attended review"))
        XCTAssertTrue(receipt.saved)
        let record = status.qualifications.first!
        let retest = try await client.retest(.init(side: .left, kind: record.kind, expectedId: record.id))
        XCTAssertTrue(retest.saved)
    }
    func testMalformedRequestsAreRejectedBeforeTransportAndPrivateFailuresStayBounded() async throws {
        let transport = transport("owner-contract.invalid"); defer { transport.session.invalidateAndCancel() }
        let client = CoreComfortOwnerClient(transport: transport)
        do { _ = try await client.prepare(.init(side: .left, purpose: .activation, kind: .cooling)); XCTFail("Bad kind dispatched") } catch { }
        do { _ = try await client.confirm(.init(side: .left, id: UUID().uuidString, confirmed: false, note: "")); XCTFail("Missing consent dispatched") } catch { }
        for host in ["owner-key.invalid", "owner-large.invalid"] {
            let transport = self.transport(host); defer { transport.session.invalidateAndCancel() }
            do { let _ = try await CoreComfortOwnerClient(transport: transport).status(side: .left); XCTFail("Expected unavailable") }
            catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE")) }
        }
    }
    private func transport(_ host: String) -> CoreRESTClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ComfortOwnerProtocol.self]
        return .init(endpoint: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration))
    }
}

private final class ComfortOwnerProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = request.url!, fixture = try ComfortOwnerExample.load(), review = fixture.reviews["activation"]!
            let body = try bodyObject(), status = fixture.statuses["ready"]!
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            var valid = request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData
            var code = 200, data = Data()
            if url.host == "owner-key.invalid" { code = 401; data = Data("{\"message\":\"PRIVATE\"}".utf8) }
            else if url.host == "owner-large.invalid" { data = Data(repeating: 32, count: 1_048_577) }
            else {
                switch url.path {
                case "/api/v1/comfort/owner":
                    valid = valid && request.httpMethod == "GET" && body.isEmpty && query == [.init(name: "side", value: "left")]
                    data = try JSONEncoder().encode(status)
                case "/api/v1/comfort/owner/prepare":
                    valid = valid && request.httpMethod == "POST" && query.isEmpty && Set(body.keys) == ["side", "purpose", "kind"]
                        && body["side"] as? String == "left" && body["purpose"] as? String == "activation" && body["kind"] is NSNull
                    data = try JSONEncoder().encode(review)
                case "/api/v1/comfort/owner/confirm":
                    valid = valid && request.httpMethod == "POST" && query.isEmpty && Set(body.keys) == ["side", "id", "confirmed", "note"]
                        && body["side"] as? String == "left" && body["id"] as? String == review.id && body["confirmed"] as? Bool == true && body["note"] as? String == "Attended review"
                    data = Data("{\"saved\":true}".utf8)
                case "/api/v1/comfort/owner/retest":
                    valid = valid && request.httpMethod == "POST" && query.isEmpty && Set(body.keys) == ["side", "kind", "expectedId"]
                        && body["side"] as? String == "left" && body["expectedId"] as? String == status.qualifications.first!.id
                        && body["kind"] as? String == status.qualifications.first!.kind.rawValue
                    data = Data("{\"saved\":true}".utf8)
                default: valid = false
                }
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: valid ? code : 422, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func bodyObject() throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        }
        return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    override func stopLoading() {}
}
