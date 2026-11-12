import XCTest
@testable import Sleepypod

@MainActor final class PersonalJournalTransportTests: XCTestCase {
    private func client(_ account: HouseholdSession? = nil) throws -> PersonalJournalHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PersonalJournalProtocol.self]
        return .init(connection: PersonalHistoryFixtures.connection(try account ?? PersonalJournalFixtures.session()), transport: URLSession(configuration: configuration))
    }
    func testOnlyOwnJournalAndReceiptRoutesUsePinnedPersonalCredential() async throws {
        let client = try client(), page = try PersonalJournalFixtures.data("page"), result = try PersonalJournalFixtures.data("receipt")
        let session = try PersonalJournalFixtures.data("session")
        let requestId = "00000000-0000-4000-8000-000000000011"
        PersonalJournalProtocol.set { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(client.connection.token)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Sleepypod-Sleeper-Id"), client.connection.session.selfSleeperId)
            XCTAssertFalse(request.httpShouldHandleCookies)
            switch request.url?.path {
            case "/api/v1/household/session": XCTAssertEqual(request.httpMethod, "GET"); return .init(body: session)
            case "/api/v1/me/journal":
                if request.httpMethod == "GET" {
                    XCTAssertEqual(request.url?.query, "date=2026-11-10"); return .init(body: page)
                }
                XCTAssertEqual(request.httpMethod, "POST"); XCTAssertNil(request.url?.query)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                return .init(body: result)
            case "/api/v1/me/journal/requests/\(requestId)": XCTAssertEqual(request.httpMethod, "GET"); return .init(body: result)
            default: XCTFail("Unexpected personal route"); return .init(status: 404)
            }
        }
        _ = try await client.session(); _ = try await client.read(date: "2026-11-10")
        _ = try await client.write(.init(requestId: requestId, expectedSessionRevision: 1, expectedAssignmentRevision: 1,
            date: "2026-11-10", expectedRevision: nil, expectedTimeZone: "America/Los_Angeles", fields: nil))
        _ = try await client.receipt(requestId: requestId)
        XCTAssertEqual(PersonalJournalProtocol.count, 4)
    }
    func testInvalidSelectorsAndMissingCapabilityNeverReachNetwork() async throws {
        PersonalJournalProtocol.set { _ in XCTFail("Unexpected request"); return .init() }
        let client = try client()
        for date in ["2026-02-30", "2026-11-10&side=right", "../owner"] {
            do { _ = try await client.read(date: date); XCTFail("Invalid date accepted") } catch {}
            do { _ = try await client.receipt(requestId: date); XCTFail("Invalid request accepted") } catch {}
        }
        let disabled: HouseholdSession = try PersonalHistoryFixtures.changed(PersonalJournalFixtures.session()) {
            var capabilities = $0["capabilities"] as! [String: Any]; capabilities.removeValue(forKey: "personalJournal"); $0["capabilities"] = capabilities
        }
        do { _ = try await self.client(disabled).read(date: "2026-11-10"); XCTFail("Missing capability accepted") } catch {}
        XCTAssertEqual(PersonalJournalProtocol.count, 0)
    }
    func testErrorsOversizedAndTruncatedResponsesDoNotRetryOrExposeServerText() async throws {
        let client = try client()
        for reply in [
            PersonalJournalProtocol.Reply(status: 403, body: Data("private server text".utf8)),
            .init(body: Data(repeating: 65, count: 524_289)), .init(type: "text/html"),
            .init(body: try PersonalJournalFixtures.data("page"), failure: true), .init(length: "524289")
        ] {
            PersonalJournalProtocol.set { _ in reply }
            do { _ = try await client.read(date: "2026-11-10"); XCTFail("Bad response accepted") }
            catch { XCTAssertFalse(error.localizedDescription.contains("private server text")) }
            XCTAssertEqual(PersonalJournalProtocol.count, 1)
        }
    }
    func testPatternsUseOnlyBoundedReadRouteAndPersonalCredential() async throws {
        let client = try client(PersonalPatternsFixtures.session()), response = try PersonalPatternsFixtures.data()
        PersonalJournalProtocol.set { request in
            XCTAssertEqual(request.url?.path, "/api/v1/me/journal/patterns")
            XCTAssertEqual(request.url?.query, "from=2026-11-01&through=2026-11-10")
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(client.connection.token)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Sleepypod-Sleeper-Id"), client.connection.session.selfSleeperId)
            return .init(body: response)
        }
        let result = try await client.patterns(range: PersonalPatternsFixtures.range)
        try result.validate(for: client.connection.session, range: PersonalPatternsFixtures.range)
        XCTAssertEqual(PersonalJournalProtocol.count, 1)
        PersonalJournalProtocol.set { _ in XCTFail("Invalid request reached network"); return .init() }
        do { _ = try await client.patterns(range: .init(from: "2026-01-01", through: "2026-11-10")); XCTFail("Unbounded request") } catch {}
        do { _ = try await self.client().patterns(range: PersonalPatternsFixtures.range); XCTFail("Missing capability") } catch {}
        XCTAssertEqual(PersonalJournalProtocol.count, 0)
    }
}

private final class PersonalJournalProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var body = Data()
        var type = "application/json"
        var length: String?
        var failure = false
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: (@Sendable (URLRequest) -> Reply)?
        var count = 0
    }
    private static let state = State()
    static var count: Int { state.lock.withLock { state.count } }
    static func set(_ handler: @escaping @Sendable (URLRequest) -> Reply) { state.lock.withLock { state.handler = handler; state.count = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "history-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.state.lock.withLock { Self.state.count += 1; return Self.state.handler }
        guard let address = request.url, let reply = handler?(request) else { return }
        var headers = ["Content-Type": reply.type]
        if let length = reply.length { headers["Content-Length"] = length }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: address, statusCode: reply.status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        if reply.failure { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
        else { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}
