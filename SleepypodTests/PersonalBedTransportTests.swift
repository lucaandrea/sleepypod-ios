import XCTest
@testable import Sleepypod

@MainActor final class PersonalBedTransportTests: XCTestCase {
    private func client() throws -> PersonalBedHTTPClient {
        let session = try PersonalControlFixtures.session(for: PersonalControlFixtures.bed())
        let connection = PersonalBedConnection(id: UUID(), endpoint: URL(string: "https://personal-http.invalid")!, token: String(repeating: "A", count: 43), session: session)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PersonalBedProtocol.self]
        return .init(connection: connection, transport: URLSession(configuration: configuration))
    }
    func testOnlyPersonalBearerAndSleeperHeaderReachFixedRoutes() async throws {
        let client = try client(), body = try PersonalControlFixtures.data("temperatureRequest")
        let request = try JSONDecoder().decode(PersonalControlRequest.self, from: body)
        let sessionData = try JSONEncoder().encode(client.connection.session)
        let bedData = try PersonalControlFixtures.data("soloBed"), receiptData = try PersonalControlFixtures.data("acknowledged")
        PersonalBedProtocol.set { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(String(repeating: "A", count: 43))")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Sleepypod-Sleeper-Id"), "00000000-0000-4000-8000-000000000003")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie")); XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertNil(request.url?.query); XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
            switch request.url?.path {
            case "/api/v1/household/session": return (200, sessionData)
            case "/api/v1/me/bed": return (200, bedData)
            case "/api/v1/me/controls": XCTAssertEqual(request.httpMethod, "POST"); return (200, receiptData)
            case "/api/v1/me/controls/00000000-0000-4000-8000-000000000005": XCTAssertEqual(request.httpMethod, "GET"); return (200, receiptData)
            default: XCTFail("Unexpected route"); return (404, Data())
            }
        }
        _ = try await client.session(); _ = try await client.bed()
        _ = try await client.submit(body); _ = try await client.receipt(request.requestId)
        XCTAssertEqual(PersonalBedProtocol.count, 4)
    }
    func testForeignScopeAndSideSelectorFailBeforeNetworking() async throws {
        let client = try client()
        PersonalBedProtocol.set { _ in XCTFail("Must not send"); return (500, Data()) }
        let scope = try PersonalControlFixtures.bed("assignedBed").scope
        let request = try PersonalControlRequest(scope: scope, action: .init(kind: "power", powered: true), now: PersonalControlFixtures.instant)
        do { _ = try await client.submit(JSONEncoder().encode(request)); XCTFail("Foreign scope") } catch {}
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: PersonalControlFixtures.data("temperatureRequest")) as? [String: Any])
        body["action"] = ["kind": "temperature", "temperatureF": 70, "holdMinutes": 30, "side": "right"]
        do { _ = try await client.submit(JSONSerialization.data(withJSONObject: body)); XCTFail("Physical side selector") } catch {}
        XCTAssertEqual(PersonalBedProtocol.count, 0)
    }
    func testMissingReceiptAndAuthenticationFailuresRemainDistinct() async throws {
        let client = try client()
        PersonalBedProtocol.set { _ in (404, Data(#"{"error":{"code":"not_ready"}}"#.utf8)) }
        do { _ = try await client.receipt(UUID()); XCTFail("Missing receipt") }
        catch { XCTAssertNotNil(error as? PersonalControlFailure) }
        for (status, expected) in [(401, HouseholdFailure.authentication), (403, .forbidden), (409, .conflict)] {
            PersonalBedProtocol.set { _ in (status, Data()) }
            do { _ = try await client.bed(); XCTFail("Error \(status)") }
            catch { XCTAssertEqual(error as? HouseholdFailure, expected) }
        }
    }
    func testRedirectStatusCannotBecomeSuccessfulData() async throws {
        let client = try client(), data = try PersonalControlFixtures.data("soloBed")
        PersonalBedProtocol.set { _ in (302, data) }
        do { _ = try await client.bed(); XCTFail("Redirect must fail") } catch {}
        XCTAssertEqual(PersonalBedProtocol.count, 1)
    }
}

private final class PersonalBedProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: (@Sendable (URLRequest) -> (Int, Data))?
        var count = 0
    }
    private static let state = State()
    static var count: Int { state.lock.withLock { state.count } }
    static func set(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        state.lock.withLock { state.handler = handler; state.count = 0 }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "personal-http.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.state.lock.withLock { Self.state.count += 1; return Self.state.handler }
        guard let url = request.url, let (status, data) = handler?(request) else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
