import XCTest
@testable import Sleepypod

@MainActor final class ArrangementTransportTests: XCTestCase {
    private func client(enabled: Bool = true) throws -> ArrangementReviewHTTPClient {
        let connection = ArrangementFixtures.connection(try ArrangementFixtures.session(enabled: enabled))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ArrangementProtocol.self]
        return .init(connection: connection, transport: URLSession(configuration: configuration))
    }
    func testFixedPersonalRoutesPinIdentityAndNeverUseCookiesOrCache() async throws {
        let client = try client(), account = try JSONEncoder().encode(client.connection.session)
        let review = try ArrangementFixtures.data("ownerReview"), index = try JSONEncoder().encode(ArrangementIndex(version: 1, review: ArrangementFixtures.review()))
        ArrangementProtocol.set { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(String(repeating: "A", count: 43))")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Sleepypod-Sleeper-Id"), client.connection.session.selfSleeperId)
            XCTAssertFalse(request.httpShouldHandleCookies); XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData); XCTAssertNil(request.url?.query)
            switch request.url?.path {
            case "/api/v1/household/session": XCTAssertEqual(request.httpMethod, "GET"); return (200, account)
            case "/api/v1/household/arrangement":
                return (200, request.httpMethod == "POST" ? review : index)
            case "/api/v1/household/arrangement/00000000-0000-4000-8000-000000000041": XCTAssertEqual(request.httpMethod, "GET"); return (200, review)
            case "/api/v1/household/arrangement/approve", "/api/v1/household/arrangement/cancel": XCTAssertEqual(request.httpMethod, "POST"); return (200, review)
            default: XCTFail("Unexpected route, including activation or owner API"); return (404, Data())
            }
        }
        _ = try await client.session(); _ = try await client.latest(); _ = try await client.review(UUID(uuidString: "00000000-0000-4000-8000-000000000041")!)
        for action in [ArrangementRequest.Action.propose, .approve, .cancel] { _ = try await client.send(action, body: ArrangementFixtures.data(action.rawValue)) }
        XCTAssertEqual(ArrangementProtocol.count, 6)
    }
    func testUnknownFieldsDisabledCapabilityAndRevisionMismatchAreRejectedBeforeSend() async throws {
        ArrangementProtocol.set { _ in XCTFail("No request allowed"); return (200, Data()) }
        let disabled = try client(enabled: false)
        do { _ = try await disabled.send(.approve, body: ArrangementFixtures.data("approve")); XCTFail("Disabled") } catch {}
        let client = try client()
        var body = try ArrangementJSON.object(ArrangementFixtures.data("approve")); body["expectedAssignmentRevision"] = 2
        do { _ = try await client.send(.approve, body: JSONSerialization.data(withJSONObject: body)); XCTFail("Revision mismatch") } catch {}
        body["expectedAssignmentRevision"] = 1; body["partnerRoutine"] = []
        do { _ = try await client.send(.approve, body: JSONSerialization.data(withJSONObject: body)); XCTFail("Unexpected field") } catch {}
        XCTAssertEqual(ArrangementProtocol.count, 0)
    }
    func testAuthenticationRedirectAndMalformedPrivateProjectionFailClosed() async throws {
        let client = try client()
        for status in [401, 403, 409, 404, 429, 503, 302] {
            ArrangementProtocol.set { _ in (status, Data()) }
            do { _ = try await client.latest(); XCTFail("Must reject \(status)") } catch {}
            XCTAssertEqual(ArrangementProtocol.count, 1)
        }
        var body = try ArrangementJSON.object(ArrangementFixtures.data("ownerReview"))
        var partner = try XCTUnwrap(body["partner"] as? [String: Any]); partner["healthHistory"] = []; body["partner"] = partner
        let invalid = try JSONSerialization.data(withJSONObject: ["version": 1, "review": body])
        ArrangementProtocol.set { _ in (200, invalid) }
        do { _ = try await client.latest(); XCTFail("Partner history must not be accepted") } catch {}
    }
}

private final class ArrangementProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: (@Sendable (URLRequest) -> (Int, Data))?
        var count = 0
    }
    private static let state = State()
    static var count: Int { state.lock.withLock { state.count } }
    static func set(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) { state.lock.withLock { state.handler = handler; state.count = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "arrangement-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.state.lock.withLock { Self.state.count += 1; return Self.state.handler }
        guard let url = request.url, let (status, data) = handler?(request) else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
