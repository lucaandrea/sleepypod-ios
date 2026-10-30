import XCTest
@testable import Sleepypod

@MainActor final class PersonalHistoryTransportTests: XCTestCase {
    private func client(enabled: Bool = true) throws -> PersonalHistoryHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PersonalHistoryProtocol.self]
        return .init(connection: PersonalHistoryFixtures.connection(try PersonalHistoryFixtures.session(enabled: enabled)), transport: URLSession(configuration: configuration))
    }
    func testFixedGetRoutesCanonicalTimesAndOpaqueCursorPinPersonalIdentity() async throws {
        let client = try client(), page = try PersonalHistoryFixtures.page(), cursor = "opaque /+?= &é🛌"
        let account = try JSONEncoder().encode(client.connection.session), pageData = try PersonalHistoryFixtures.data("page"), detail = try PersonalHistoryFixtures.data("detail")
        PersonalHistoryProtocol.set { request in
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(String(repeating: "A", count: 43))")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Sleepypod-Sleeper-Id"), client.connection.session.selfSleeperId)
            XCTAssertFalse(request.httpShouldHandleCookies); XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
            switch request.url?.path {
            case "/api/v1/household/session": XCTAssertNil(request.url?.query); return (200, account)
            case "/api/v1/me/sleep":
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(query, ["startsAt": String(page.query.startsAt), "endsAt": String(page.query.endsAt), "kind": "presence", "limit": "30", "cursor": cursor])
                let encodedCursor = request.url!.query!.split(separator: "&").first { $0.hasPrefix("cursor=") }!.dropFirst("cursor=".count)
                let serverCursor = String(encodedCursor).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
                XCTAssertEqual(serverCursor, cursor)
                return (200, pageData)
            case "/api/v1/me/sleep/10000000-0000-4000-8000-000000000001": XCTAssertNil(request.url?.query); return (200, detail)
            default: XCTFail("Unexpected owner, side or mutation route"); return (404, Data())
            }
        }
        _ = try await client.session(); _ = try await client.page(page.query, cursor: cursor)
        _ = try await client.detail(UUID(uuidString: "10000000-0000-4000-8000-000000000001")!)
        XCTAssertEqual(PersonalHistoryProtocol.count, 3)
    }
    func testUnavailableCapabilityInvalidQueryAndOversizedCursorNeverSend() async throws {
        PersonalHistoryProtocol.set { _ in XCTFail("No request allowed"); return (200, Data()) }
        let disabled = try client(enabled: false), page = try PersonalHistoryFixtures.page()
        do { _ = try await disabled.page(page.query, cursor: nil); XCTFail("Disabled") } catch {}
        do { _ = try await disabled.detail(UUID()); XCTFail("Disabled") } catch {}
        let client = try client()
        for cursor in ["", String(repeating: "x", count: 4_097)] {
            do { _ = try await client.page(page.query, cursor: cursor); XCTFail("Invalid cursor") } catch {}
        }
        do { _ = try await client.page(.init(startsAt: 0, endsAt: 1, kind: .presence, limit: 101), cursor: nil); XCTFail("Invalid limit") } catch {}
        XCTAssertEqual(PersonalHistoryProtocol.count, 0)
    }
    func testErrorsRedirectAndTruncatedBodyFailWithoutResponseDisclosureOrRetry() async throws {
        let client = try client(), page = try PersonalHistoryFixtures.page()
        for (status, expected): (Int, HouseholdFailure) in [(401, .authentication), (403, .forbidden), (404, .unavailable), (409, .conflict), (429, .rateLimited), (503, .unavailable), (302, .invalid)] {
            PersonalHistoryProtocol.set { _ in (status, Data("private-response-content".utf8)) }
            do { _ = try await client.page(page.query, cursor: nil); XCTFail("Must fail") }
            catch { XCTAssertEqual(error as? HouseholdFailure, expected); XCTAssertFalse(error.localizedDescription.contains("private-response-content")) }
            XCTAssertEqual(PersonalHistoryProtocol.count, 1)
        }
        for body in [Data("{\"records\":[".utf8), Data(repeating: 32, count: 524_289)] {
            PersonalHistoryProtocol.set { _ in (200, body) }
            do { _ = try await client.page(page.query, cursor: nil); XCTFail("Invalid body") } catch {}
            XCTAssertEqual(PersonalHistoryProtocol.count, 1)
        }
        PersonalHistoryProtocol.set { _ in (-1, Data()) }
        do { _ = try await client.page(page.query, cursor: nil); XCTFail("Aborted") }
        catch { XCTAssertEqual(error as? HouseholdFailure, .uncertain) }
        XCTAssertEqual(PersonalHistoryProtocol.count, 1)
    }
}

private final class PersonalHistoryProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: (@Sendable (URLRequest) -> (Int, Data))?
        var count = 0
    }
    private static let state = State()
    static var count: Int { state.lock.withLock { state.count } }
    static func set(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) { state.lock.withLock { state.handler = handler; state.count = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "history-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.state.lock.withLock { Self.state.count += 1; return Self.state.handler }
        guard let url = request.url, let (status, data) = handler?(request) else { return }
        if status == -1 { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
