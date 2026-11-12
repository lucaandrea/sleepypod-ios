import XCTest
@testable import Sleepypod

@MainActor final class ArrangementMaintenanceTransportTests: XCTestCase {
    private func client() throws -> ArrangementMaintenanceHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MaintenanceProtocol.self]
        return .init(connection: ArrangementFixtures.connection(try MaintenanceFixtures.session()),
                     transport: URLSession(configuration: configuration), clock: { MaintenanceFixtures.now })
    }
    func testReadRoutesUseOnlyPersonalCredentialsAndAnOptionalOperationId() async throws {
        let client = try client(), account = try JSONEncoder().encode(client.connection.session)
        let status = try MaintenanceFixtures.data("held"), preview = try MaintenanceFixtures.data("cancellationPreview")
        MaintenanceProtocol.set { request in
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
            XCTAssertFalse(request.httpShouldHandleCookies); XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(String(repeating: "A", count: 43))")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Sleepypod-Sleeper-Id"), client.connection.session.selfSleeperId)
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(items.isEmpty || items == [URLQueryItem(name: "operationId", value: MaintenanceFixtures.operationId)])
            switch request.url?.path {
            case "/api/v1/household/session": return (200, account)
            case "/api/v1/household/transition": return (200, status)
            case "/api/v1/household/transition/cancellation-preview": return (200, preview)
            default: XCTFail("Only maintenance read routes are allowed"); return (500, Data())
            }
        }
        _ = try await client.session()
        _ = try await client.status()
        _ = try await client.status(operationId: UUID(uuidString: MaintenanceFixtures.operationId))
        _ = try await client.cancellationPreview(operationId: UUID(uuidString: MaintenanceFixtures.operationId)!)
        XCTAssertEqual(MaintenanceProtocol.count, 4)
    }
    func testRestartIsOnePostAndAcceptsOnlyItsExactReceipt() async throws {
        let client = try client(), account = client.connection.session
        let request = try ArrangementMaintenanceRequest.decodeExact(MaintenanceFixtures.data("restartRequest"), action: .restart, session: account, now: MaintenanceFixtures.now)
        let source = try ArrangementJSON.object(MaintenanceFixtures.data("restartSubmitted"))
        let operation = try XCTUnwrap(source["operation"] as? [String: Any])
        let response = try JSONSerialization.data(withJSONObject: ["receipt": XCTUnwrap(operation["restart"]), "replayed": false])
        MaintenanceProtocol.set { observed in
            XCTAssertEqual(observed.httpMethod, "POST"); XCTAssertEqual(observed.url?.path, "/api/v1/household/transition/restart")
            XCTAssertNil(observed.url?.query)
            XCTAssertEqual(MaintenanceProtocol.body(observed), request.body)
            return (200, response)
        }
        guard case .restarted(let receipt, let replayed) = try await client.send(request, session: account) else { return XCTFail("Expected restart receipt") }
        XCTAssertEqual(receipt.requestId, request.requestId); XCTAssertFalse(replayed); XCTAssertFalse(receipt.replayAllowed)
        XCTAssertEqual(MaintenanceProtocol.count, 1)
    }
    func testExpiredOrDifferentOwnerRequestsAreRejectedBeforeNetworking() async throws {
        var client = try client()
        let account = client.connection.session
        let request = try ArrangementMaintenanceRequest.decodeExact(MaintenanceFixtures.data("restartRequest"), action: .restart, session: account, now: MaintenanceFixtures.now)
        MaintenanceProtocol.set { _ in XCTFail("No request permitted"); return (200, Data()) }
        let other = try PersonalRoutineFixtures.changed(account) { $0["selfSleeperId"] = UUID().uuidString }
        do { _ = try await client.send(request, session: other); XCTFail("Changed identity") } catch {}
        client.clock = { MaintenanceFixtures.now + 60_000 }
        do { _ = try await client.send(request, session: account); XCTFail("Expired") } catch {}
        XCTAssertEqual(MaintenanceProtocol.count, 0)
    }
    func testFailureAndUnexpectedProjectionNeverTriggerAnAutomaticRetry() async throws {
        let client = try client(), account = client.connection.session
        let request = try ArrangementMaintenanceRequest.decodeExact(MaintenanceFixtures.data("restartRequest"), action: .restart, session: account, now: MaintenanceFixtures.now)
        for code in [401, 403, 404, 409, 429, 500, 503, 302] {
            MaintenanceProtocol.set { _ in (code, Data()) }
            do { _ = try await client.send(request, session: account); XCTFail("Reject \(code)") } catch {}
            XCTAssertEqual(MaintenanceProtocol.count, 1)
        }
        let expanded = try MaintenanceFixtures.changed("held") { $0["ownerSecret"] = "not-a-real-secret" }
        MaintenanceProtocol.set { _ in (200, expanded) }
        do { _ = try await client.status(); XCTFail("Unexpected private fields") } catch {}
        XCTAssertEqual(MaintenanceProtocol.count, 1)
    }
    func testResultsKeepServiceStartupSeparateAndRejectMismatchedReceipts() throws {
        let account = try MaintenanceFixtures.session()
        for action in [ArrangementMaintenanceRequest.Action.recover, .cancel] {
            let request = try ArrangementMaintenanceRequest.decodeExact(MaintenanceFixtures.data("\(action.rawValue)Request"), action: action, session: account, now: MaintenanceFixtures.now)
            let source = try ArrangementJSON.object(MaintenanceFixtures.data(action == .recover ? "completed" : "cancelled"))
            let operation = try XCTUnwrap(source["operation"] as? [String: Any])
            var receipt = try XCTUnwrap(operation[action == .recover ? "recovery" : "cancellation"] as? [String: Any])
            for services in ["resumed", "unavailable", "unchanged_by_replay"] {
                let response = try JSONSerialization.data(withJSONObject: ["receipt": receipt, "automaticServices": services, "replayed": false])
                _ = try ArrangementMaintenanceResult.decodeExact(response, request: request)
            }
            receipt["requestId"] = UUID().uuidString
            let mismatched = try JSONSerialization.data(withJSONObject: ["receipt": receipt, "automaticServices": "resumed", "replayed": false])
            XCTAssertThrowsError(try ArrangementMaintenanceResult.decodeExact(mismatched, request: request))
            receipt["requestId"] = request.requestId; receipt["partnerHistory"] = []
            let expanded = try JSONSerialization.data(withJSONObject: ["receipt": receipt, "automaticServices": "resumed", "replayed": false])
            XCTAssertThrowsError(try ArrangementMaintenanceResult.decodeExact(expanded, request: request))
        }
    }
}

private final class MaintenanceProtocol: URLProtocol, @unchecked Sendable {
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
    static func body(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0, data.count + count <= 16_384 else { return nil }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
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
