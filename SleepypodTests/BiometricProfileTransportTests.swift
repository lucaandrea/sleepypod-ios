import XCTest
@testable import Sleepypod

@MainActor final class BiometricProfileTransportTests: XCTestCase {
    func testLiteralCoreOverviewAndPairedPageCursor() async throws {
        let fixture = ProfileHTTPFixture(); defer { fixture.close() }
        let overviewURL = try XCTUnwrap(Bundle.main.url(forResource: "biometric-profile-overview", withExtension: "json"))
        fixture.state.responses = [try Data(contentsOf: overviewURL), Data(#"{"items":[],"nextCursor":null}"#.utf8), Data(#"{"items":[],"nextGeneration":null}"#.utf8)]
        let overview = try await fixture.client.overview(side: .left)
        XCTAssertEqual(overview.desired.binding.generation, 0); XCTAssertEqual(overview.stageView.provenance.source, "default")
        XCTAssertEqual(overview.runtimeHealth.components.map(\.component), ["heart_rate", "breathing_rate", "hrv_index"])
        let cursor = BiometricProfilePage.Cursor(createdAtMs: 1792920000123, id: "10000000-0000-4000-8000-000000000001")
        _ = try await fixture.client.profiles(side: .right, cursor: cursor)
        _ = try await fixture.client.history(side: .left, beforeGeneration: 17)
        let requests = fixture.state.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "GET", "GET"])
        XCTAssertEqual(requests.map(\.path), ["/api/biometric-tuning/profiles/overview", "/api/biometric-tuning/profiles", "/api/biometric-tuning/activations"])
        XCTAssertEqual(requests[0].query, ["side": "left"])
        XCTAssertEqual(requests[1].query, ["side": "right", "beforeCreatedAtMs": "1792920000123", "beforeId": cursor.id])
        XCTAssertEqual(requests[2].query, ["side": "left", "beforeGeneration": "17"])
    }
    func testMutationsSendExactRESTBodiesWithoutTRPCEnvelopeOrAutomaticRetry() async throws {
        let fixture = ProfileHTTPFixture(); defer { fixture.close() }
        fixture.state.failWrites = true
        let request = BiometricCandidateRequest(side: .right, parentRevisionId: nil, baseManifestHash: String(repeating: "b", count: 64), overrides: [.init(path: "hrv_index.minimumWindows", value: .number(15))], origin: "manual", requester: "ios-calibration", idempotencyKey: "stable-candidate")
        do { _ = try await fixture.client.create(request); XCTFail("Expected lost reply") } catch {}
        let activation = BiometricActivationRequest(action: .rollback, side: .right, revisionId: nil, expectedGeneration: 8, expectedResolvedHash: String(repeating: "c", count: 64), boundary: .nextSession, requester: "ios-calibration", idempotencyKey: "stable-activation", allowUnvalidated: true)
        do { _ = try await fixture.client.activate(activation); XCTFail("Expected lost reply") } catch {}
        let requests = fixture.state.requests
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests.map(\.method), ["POST", "POST"])
        XCTAssertEqual(requests[0].path, "/api/biometric-tuning/profiles")
        XCTAssertEqual(Set(requests[0].body.keys), ["side", "baseManifestHash", "overrides", "origin", "requester", "idempotencyKey"])
        XCTAssertEqual(requests[0].body["idempotencyKey"] as? String, "stable-candidate")
        XCTAssertEqual(requests[1].path, "/api/biometric-tuning/rollback")
        XCTAssertTrue(requests[1].body["revisionId"] is NSNull)
        XCTAssertNil(requests[1].body["action"]); XCTAssertNil(requests[1].body["json"])
        XCTAssertEqual(requests[1].body["expectedGeneration"] as? Int, 8)
        XCTAssertEqual(requests[1].body["expectedResolvedHash"] as? String, activation.expectedResolvedHash)
        XCTAssertEqual(requests[1].body["boundary"] as? String, "next_session")
    }
    func testInvalidIdentifiersCannotEscapeRoutePath() async throws {
        let fixture = ProfileHTTPFixture(); defer { fixture.close() }
        do { _ = try await fixture.client.profile(id: "../reset"); XCTFail("Expected invalid ID") } catch {}
        do { _ = try await fixture.client.compatibility(side: .left, id: "fake?side=right"); XCTFail("Expected invalid ID") } catch {}
        XCTAssertTrue(fixture.state.requests.isEmpty)
    }
}

private final class ProfileHTTPFixture {
    let host = "profiles-\(UUID().uuidString.lowercased()).invalid"
    let state = ProfileHTTPState()
    let session: URLSession
    var client: CoreBiometricProfilesClient { .init(transport: .init(endpoint: URL(string: "https://\(host)")!, session: session)) }
    init() {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ProfileHTTPProtocol.self]
        session = URLSession(configuration: config); ProfileHTTPProtocol.registry.register(state, host: host)
    }
    func close() { session.invalidateAndCancel(); ProfileHTTPProtocol.registry.remove(host) }
}
private final class ProfileHTTPState: @unchecked Sendable {
    struct Request { let method: String; let path: String; let query: [String: String]; let body: [String: Any] }
    private let lock = NSLock()
    private var values: [Data] = []
    private var writesFail = false
    private var received: [Request] = []
    var responses: [Data] { get { lock.withLock { values } } set { lock.withLock { values = newValue } } }
    var failWrites: Bool { get { lock.withLock { writesFail } } set { lock.withLock { writesFail = newValue } } }
    var requests: [Request] { lock.withLock { received } }
    func reply(_ request: URLRequest) throws -> Data {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        }
        let body = data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return try lock.withLock {
            received.append(.init(method: request.httpMethod ?? "", path: request.url!.path, query: Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }), body: body))
            if writesFail && request.httpMethod != "GET" { throw URLError(.timedOut) }
            guard !values.isEmpty else { throw URLError(.badServerResponse) }; return values.removeFirst()
        }
    }
}
private final class ProfileHTTPRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ProfileHTTPState] = [:]
    func register(_ state: ProfileHTTPState, host: String) { lock.withLock { values[host] = state } }
    func remove(_ host: String) { _ = lock.withLock { values.removeValue(forKey: host) } }
    func state(_ host: String) -> ProfileHTTPState? { lock.withLock { values[host] } }
}
private final class ProfileHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let registry = ProfileHTTPRegistry()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host.flatMap(registry.state) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let state = Self.registry.state(url.host ?? "") else { return }
        do {
            let data = try state.reply(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
