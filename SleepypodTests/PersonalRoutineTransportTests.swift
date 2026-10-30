import XCTest
@testable import Sleepypod

@MainActor final class PersonalRoutineTransportTests: XCTestCase {
    private func client() throws -> PersonalRoutineHTTPClient {
        let connection = PersonalBedConnection(id: UUID(), endpoint: URL(string: "https://routine-http.invalid")!, token: String(repeating: "A", count: 43), session: try PersonalRoutineFixtures.session())
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PersonalRoutineProtocol.self]
        return .init(connection: connection, transport: URLSession(configuration: configuration))
    }
    func testOnlyFixedPersonalRoutesCredentialsAndExactBodyAreUsed() async throws {
        let client = try client(), request: PersonalRoutineRequest = try PersonalRoutineFixtures.decode("publishRequest")
        let body = try JSONEncoder().encode(request)
        let account = try JSONEncoder().encode(client.connection.session)
        let review = try PersonalControlFixtures.data("readyReview", file: "personal-routines-v1")
        let receipt = try PersonalControlFixtures.data("saved", file: "personal-routines-v1")
        PersonalRoutineProtocol.set { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(String(repeating: "A", count: 43))")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Sleepypod-Sleeper-Id"), client.connection.session.selfSleeperId)
            XCTAssertFalse(request.httpShouldHandleCookies); XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData); XCTAssertNil(request.url?.query)
            switch request.url?.path {
            case "/api/v1/household/session": return (200, account)
            case "/api/v1/me/routines/review": return (200, review)
            case "/api/v1/me/routines/publish":
                XCTAssertEqual(request.httpMethod, "POST")
                if let sent = request.httpBody { XCTAssertEqual(sent, body) }
                else if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var bytes = [UInt8](repeating: 0, count: 4096)
                    let count = stream.read(&bytes, maxLength: bytes.count); XCTAssertEqual(Data(bytes.prefix(max(0, count))), body)
                } else { XCTFail("Missing exact body") }
                return (200, receipt)
            case "/api/v1/me/routines/publications/00000000-0000-4000-8000-000000000006": XCTAssertEqual(request.httpMethod, "GET"); return (200, receipt)
            default: XCTFail("Unexpected owner or other route"); return (404, Data())
            }
        }
        _ = try await client.session(); _ = try await client.review(); _ = try await client.publish(body); _ = try await client.publication(request.requestId)
        XCTAssertEqual(PersonalRoutineProtocol.count, 4)
    }
    func testMissingReceiptAuthenticationRedirectAndForeignPublishFailClosed() async throws {
        let client = try client()
        PersonalRoutineProtocol.set { _ in (404, Data()) }
        do { _ = try await client.publication(UUID()); XCTFail("404") } catch { XCTAssertNotNil(error as? PersonalRoutineFailure) }
        for status in [401, 403, 409, 302] {
            PersonalRoutineProtocol.set { _ in (status, Data()) }
            do { _ = try await client.review(); XCTFail("Must fail \(status)") } catch {}
            XCTAssertEqual(PersonalRoutineProtocol.count, 1)
        }
        let request: PersonalRoutineRequest = try PersonalRoutineFixtures.decode("publishRequest")
        let foreign = try PersonalRoutineFixtures.changed(request) {
            var scope = $0["scope"] as? [String: Any] ?? [:]; scope["sleeperId"] = UUID().uuidString; $0["scope"] = scope
        }
        PersonalRoutineProtocol.set { _ in XCTFail("No request expected"); return (200, Data()) }
        do { _ = try await client.publish(JSONEncoder().encode(foreign)); XCTFail("Foreign account") } catch {}
        XCTAssertEqual(PersonalRoutineProtocol.count, 0)
    }
}

private final class PersonalRoutineProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: (@Sendable (URLRequest) -> (Int, Data))?
        var count = 0
    }
    private static let state = State()
    static var count: Int { state.lock.withLock { state.count } }
    static func set(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) { state.lock.withLock { state.handler = handler; state.count = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "routine-http.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.state.lock.withLock { Self.state.count += 1; return Self.state.handler }
        guard let url = request.url, let (status, data) = handler?(request) else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
