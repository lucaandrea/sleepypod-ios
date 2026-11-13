import XCTest
@testable import Sleepypod

@MainActor final class BedtimeRitualTransportTests: XCTestCase {
    private let scope = "confirmed-audio-account-scope"
    private let token = String(repeating: "A", count: 43)
    private func client(account: BedtimeRitualQuietClient.Account) -> BedtimeRitualQuietClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RitualProtocol.self]
        return .init(endpoint: URL(string: "https://ritual-fixture.invalid")!, token: token, scope: scope, account: account,
            transport: URLSession(configuration: config, delegate: PersonalHistoryRedirectPolicy(), delegateQueue: nil))
    }
    func testOwnerChecksInstallationBeforeAndAfterRestrictedSharedRead() async throws {
        let installation = UUID(), token = token
        let shared = Data(#"{"version":1,"generatedAt":1800000000000,"expiresAt":1800000015000,"shared":{"paused":false,"until":null}}"#.utf8)
        RitualProtocol.set { request, _ in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Sleepypod-Sleeper-Id"))
            if request.url?.path == "/api/v1/connection" {
                let challenge = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!
                let value: [String: Any] = ["schemaVersion": 1, "controller": "sleepypod-core", "installationId": installation.uuidString, "challenge": challenge]
                return .init(data: try! JSONSerialization.data(withJSONObject: value))
            }
            XCTAssertEqual(request.url?.path, "/api/v1/household/shared-quiet")
            XCTAssertNil(request.url?.query); XCTAssertFalse(request.httpShouldHandleCookies)
            return .init(data: shared)
        }
        let result = try await client(account: .owner(installation)).read()
        XCTAssertFalse(result.paused); XCTAssertEqual(result.scope, scope)
        XCTAssertEqual(RitualProtocol.count, 3)
    }
    func testPersonalReadsRemainScopedBeforeAndAfterQuietReading() async throws {
        let session = try PersonalQuietFixtures.session(), token = token
        let data = try JSONEncoder().encode(session), quiet = try PersonalQuietFixtures.data("partner")
        RitualProtocol.set { request, count in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Sleepypod-Sleeper-Id"), session.selfSleeperId)
            XCTAssertEqual(request.url?.path, count == 2 ? "/api/v1/me/quiet" : "/api/v1/household/session")
            XCTAssertFalse(request.httpShouldHandleCookies)
            return .init(data: count == 2 ? quiet : data)
        }
        let result = try await client(account: .personal(session)).read()
        XCTAssertTrue(result.paused); XCTAssertEqual(result.scope, scope)
        XCTAssertEqual(RitualProtocol.count, 3)
    }
    func testChangedPersonalSessionAfterQuietReadWithdrawsTheResult() async throws {
        let session = try PersonalQuietFixtures.session(), quiet = try PersonalQuietFixtures.data("idle")
        let original = try JSONEncoder().encode(session)
        let changed = try JSONEncoder().encode(PersonalHistoryFixtures.changed(session) { $0["assignmentRevision"] = session.assignmentRevision + 1 })
        RitualProtocol.set { _, count in .init(data: count == 2 ? quiet : count == 3 ? changed : original) }
        do { _ = try await client(account: .personal(session)).read(); XCTFail("Must withdraw") }
        catch { XCTAssertEqual(error as? BedtimeRitualFailure, .accountChanged) }
    }
    func testNoOwnerFallbackOnRevocationOrMissingCapability() async throws {
        var session = try PersonalQuietFixtures.session()
        for status in [401, 403, 404, 503] {
            RitualProtocol.set { _, _ in .init(status: status, data: Data("private-error-body".utf8)) }
            do { _ = try await client(account: .personal(session)).read(); XCTFail("Must reject") }
            catch {
                XCTAssertEqual(error as? BedtimeRitualFailure, [401, 403].contains(status) ? .accountChanged : .quietUnavailable)
                XCTAssertFalse(error.localizedDescription.contains("private-error"))
            }
            XCTAssertEqual(RitualProtocol.count, 1)
        }
        session = try PersonalHistoryFixtures.changed(session) {
            var capabilities = $0["capabilities"] as! [String: Any]; capabilities["householdQuiet"] = false; $0["capabilities"] = capabilities
        }
        RitualProtocol.set { _, _ in XCTFail("No fallback"); return .init(data: Data()) }
        do { _ = try await client(account: .personal(session)).read(); XCTFail("Missing capability") } catch {}
        XCTAssertEqual(RitualProtocol.count, 0)
    }
    func testPersonalResponseBoundsRejectMIMEOriginBodyAndRedirectFailures() async throws {
        let session = try PersonalQuietFixtures.session(), original = try JSONEncoder().encode(PersonalQuietFixtures.session())
        let cases = [RitualProtocol.Reply(status: 302, data: original), .init(data: original, mime: "text/html"),
                     .init(data: Data(repeating: 32, count: 16_385)), .init(data: Data("{".utf8)),
                     .init(data: original, address: URL(string: "https://other.invalid/api/v1/household/session"))]
        for reply in cases {
            RitualProtocol.set { _, _ in reply }
            do { _ = try await client(account: .personal(session)).read(); XCTFail("Must reject") } catch {}
            XCTAssertEqual(RitualProtocol.count, 1)
        }
    }
    func testOwnerPayloadCannotCarryExtraIdentityOrContradictoryQuietClocks() throws {
        let valid: [String: Any] = ["version": 1, "generatedAt": 1000, "expiresAt": 16000,
                                  "shared": ["paused": false, "until": NSNull()]]
        for key in ["accountId", "expiresAt", "shared", "version"] {
            var value = valid
            switch key {
            case "expiresAt": value[key] = 1000
            case "shared": value[key] = ["paused": true, "until": NSNull()]
            case "version": value[key] = 2
            default: value[key] = "private"
            }
            XCTAssertThrowsError(try BedtimeRitualQuietClient.ownerReading(JSONSerialization.data(withJSONObject: value), scope: scope))
        }
    }
    func testNamespaceSeparatesAccountTypesAndPreservesArrayBoundaries() throws {
        XCTAssertNotEqual(try BedtimeRitualConnection.namespace(["a|b", "c"]), try BedtimeRitualConnection.namespace(["a", "b|c"]))
        XCTAssertNotEqual(try BedtimeRitualConnection.namespace(["owner", "a"]), try BedtimeRitualConnection.namespace(["personal", "a"]))
    }
}

private final class RitualProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        let data: Data
        var mime = "application/json"
        var address: URL?
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: (@Sendable (URLRequest, Int) -> Reply)?
        var count = 0
    }
    private static let state = State()
    static var count: Int { state.lock.withLock { state.count } }
    static func set(_ handler: @escaping @Sendable (URLRequest, Int) -> Reply) {
        state.lock.withLock { state.handler = handler; state.count = 0 }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "ritual-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (handler, count) = Self.state.lock.withLock { Self.state.count += 1; return (Self.state.handler, Self.state.count) }
        guard let address = request.url, let reply = handler?(request, count) else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: reply.address ?? address, statusCode: reply.status, httpVersion: nil,
            headerFields: ["Content-Type": reply.mime])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
