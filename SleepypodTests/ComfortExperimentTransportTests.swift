import XCTest
@testable import Sleepypod

@MainActor final class ComfortExperimentTransportTests: XCTestCase {
    private func client(execution: Bool = true) throws -> ComfortExperimentHTTPClient {
        let account = try JSONDecoder().decode(HouseholdSession.self, from: ComfortExperimentFixtures.changed(JSONEncoder().encode(ComfortExperimentFixtures.session())) { object in
            var capabilities = object["capabilities"] as! [String: Any]
            capabilities["comfortExperimentExecution"] = execution; object["capabilities"] = capabilities
        })
        let connection = PersonalHistoryFixtures.connection(account)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ComfortExperimentProtocol.self]
        return .init(account: .personal(connection), session: URLSession(configuration: configuration))
    }
    func testPersonalTransportUsesOwnCredentialAndNoCallerChosenSide() async throws {
        let client = try client(), saved: ComfortExperimentDetail = try ComfortExperimentFixtures.value("saved")
        let body = try ComfortExperimentFixtures.data("saved")
        ComfortExperimentProtocol.set { request in
            XCTAssertEqual(request.url?.path, "/api/v1/me/comfort-experiments/\(saved.record.plan.id)")
            XCTAssertNil(request.url?.query); XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Sleepypod-Sleeper-Id"), saved.scope.sleeperId)
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
            XCTAssertFalse(request.httpShouldHandleCookies)
            return .init(body: body)
        }
        let returned = try await client.request(.detail(saved.record.plan.id))
        XCTAssertEqual(returned, body); XCTAssertEqual(ComfortExperimentProtocol.count, 1)
    }
    func testRequestValidationAndExecutionCapabilityRejectBeforeNetwork() async throws {
        let client = try client(execution: false), id = UUID().uuidString
        ComfortExperimentProtocol.set { _ in XCTFail("Unexpected network request"); return .init() }
        for request in [ComfortExperimentRequest.detail("../controls"), .reviewControl(id), .confirmControl(id: id, reviewId: id, hash: String(repeating: "a", count: 64))] {
            do { _ = try await client.request(request); XCTFail("Invalid or unavailable request accepted") } catch {}
        }
        XCTAssertEqual(ComfortExperimentProtocol.count, 0)
    }
    func testOversizedWrongContentTypeInterruptedAndAuthenticationRepliesNeverRetry() async throws {
        let client = try client(), id = UUID().uuidString
        for reply in [ComfortExperimentProtocol.Reply(status: 401), .init(status: 403), .init(type: "text/html"),
                      .init(body: Data(repeating: 32, count: 524_289)), .init(length: "524289"), .init(failure: true)] {
            ComfortExperimentProtocol.set { _ in reply }
            do { _ = try await client.request(.detail(id)); XCTFail("Bad response accepted") } catch {}
            XCTAssertEqual(ComfortExperimentProtocol.count, 1)
        }
    }
    func testOnlyKnownBoundedReadinessErrorsArePresented() async throws {
        let client = try client(), id = UUID().uuidString
        let cases = [
            ("not_ready", "Reviewed nights are still missing.", true),
            ("internal_error", "private server configuration", false),
            ("not_ready", String(repeating: "a", count: 2001), false)
        ]
        for (code, message, expected) in cases {
            let body = try JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": message]])
            ComfortExperimentProtocol.set { _ in .init(status: 409, body: body) }
            do { _ = try await client.request(.reviewControl(id)); XCTFail("Error accepted") }
            catch { XCTAssertEqual(error is ComfortExperimentFailure, expected) }
            XCTAssertEqual(ComfortExperimentProtocol.count, 1)
        }
    }
    func testFreshSessionMustMatchAccountAssignmentAndCapabilities() async throws {
        let client = try client(), account = try ComfortExperimentFixtures.session()
        let session = try JSONEncoder().encode(account)
        ComfortExperimentProtocol.set { request in
            XCTAssertEqual(request.url?.path, "/api/v1/household/session")
            return .init(body: session)
        }
        let access = try await client.access()
        XCTAssertEqual(access.scope, .personal(account)); XCTAssertTrue(access.execution)
        let changed = try ComfortExperimentFixtures.changed(session) { $0["assignmentRevision"] = 2 }
        ComfortExperimentProtocol.set { _ in .init(body: changed) }
        do { _ = try await client.access(); XCTFail("Changed assignment accepted") }
        catch { XCTAssertEqual(error as? HouseholdFailure, .changedIdentity) }
    }
}

private final class ComfortExperimentProtocol: URLProtocol, @unchecked Sendable {
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
