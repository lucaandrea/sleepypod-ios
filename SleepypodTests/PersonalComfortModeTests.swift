import XCTest
@testable import Sleepypod

@MainActor final class PersonalComfortModeTests: XCTestCase {
    func testModeOnlyStopPreservesConfigurationChangedAfterScreenLoad() async throws {
        let client = ComfortModeTestClient(), model = PersonalComfortWorkspace()
        var config = try PersonalComfortExample.load().status.state!.config; config.mode = "preview"
        _ = try await client.configure(side: .left, config: config)
        model.configure(client: client, side: .left); await model.load()
        config.minimumF = 68; config.maximumF = 91; config.sensorAware = true; config.followBedtime = true
        _ = try await client.configure(side: .left, config: config)
        let stopped = await model.stopPreview(); XCTAssertTrue(stopped, model.error ?? "No stop error")
        config.mode = "off"; XCTAssertEqual(model.status?.state?.config, config)
        let calls = await client.modeCalls, configurationCalls = await client.configurationCalls
        XCTAssertEqual(calls, 1); XCTAssertEqual(configurationCalls, 2, "Stopping must not resend a full configuration")
    }
    func testUnconfirmedStopRequiresExplicitReadWithoutReplay() async throws {
        let client = ComfortModeTestClient(), model = PersonalComfortWorkspace()
        model.configure(client: client, side: .left); await model.load(); await client.loseModeResponse()
        let stopped = await model.stopPreview(); XCTAssertFalse(stopped); XCTAssertTrue(model.requiresReload)
        let retried = await model.stopPreview(); XCTAssertFalse(retried); await model.load(); XCTAssertNil(model.status)
        await model.load(userInitiated: true); XCTAssertEqual(model.status?.state?.config.mode, "off")
        let calls = await client.modeCalls; XCTAssertEqual(calls, 1)
    }
    func testCancelledSentModeChangeRequiresReadbackWithoutReplay() async throws {
        let client = ComfortModeTestClient(), model = PersonalComfortWorkspace()
        model.configure(client: client, side: .left); await model.load(); await client.holdMode()
        let task = Task { await model.stopPreview() }; await client.waitUntilHeld(); task.cancel(); await client.releaseMode()
        let stopped = await task.value; XCTAssertFalse(stopped); XCTAssertTrue(model.requiresReload); XCTAssertNil(model.status)
        let retry = await model.stopPreview(); XCTAssertFalse(retry); await model.load(); XCTAssertNil(model.status)
        await model.load(userInitiated: true); XCTAssertEqual(model.status?.state?.config.mode, "off")
        let count = await client.modeCalls; XCTAssertEqual(count, 1)
    }
    func testOwnerChangeAndAlreadyCancelledStopCannotDispatch() async throws {
        let client = ComfortModeTestClient(), model = PersonalComfortWorkspace()
        model.configure(client: client, side: .left); await model.load()
        let old = UserDefaults.standard.string(forKey: "ownerConnectionRevision")
        defer { UserDefaults.standard.set(old, forKey: "ownerConnectionRevision") }
        UserDefaults.standard.set(UUID().uuidString, forKey: "ownerConnectionRevision")
        let stale = await model.stopPreview(); XCTAssertFalse(stale)
        UserDefaults.standard.set(old, forKey: "ownerConnectionRevision")
        let task = Task { await model.stopPreview() }; task.cancel()
        let cancelled = await task.value; XCTAssertFalse(cancelled)
        let count = await client.modeCalls; XCTAssertEqual(count, 0)
    }
    func testModeRESTSendsOnlySideAndModeAndRejectsActiveBeforeDispatch() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ComfortModeProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let client = CorePersonalComfortClient(transport: .init(endpoint: URL(string: "https://comfort-mode.invalid")!, session: session))
        let response = try await client.mode(side: .left, mode: "off"); XCTAssertEqual(response.state?.config.mode, "off")
        do { _ = try await client.mode(side: .left, mode: "active"); XCTFail("Active must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not available")) }
    }
}

private actor ComfortModeTestClient: PersonalComfortClient {
    private let delegate = DemoPersonalComfortClient()
    private var loseResponse = false
    private var holdResponse = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var modeCalls = 0
    private(set) var configurationCalls = 0
    func status(side: Side) async throws -> PersonalComfortStatus {
        let result = try await delegate.status(side: side)
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [String: Any]
        var features = body["features"] as! [String: Any]; features["modeOnly"] = true; body["features"] = features
        return try JSONDecoder().decode(PersonalComfortStatus.self, from: JSONSerialization.data(withJSONObject: body))
    }
    func configure(side: Side, config: PersonalComfortConfig) async throws -> PersonalComfortStatus { configurationCalls += 1; return try await delegate.configure(side: side, config: config) }
    func mode(side: Side, mode: String) async throws -> PersonalComfortStatus {
        modeCalls += 1; _ = try await delegate.mode(side: side, mode: mode)
        if holdResponse { holdResponse = false; await withCheckedContinuation { continuation = $0 } }
        if loseResponse { loseResponse = false; throw URLError(.networkConnectionLost) }; return try await status(side: side)
    }
    func loseModeResponse() { loseResponse = true }
    func holdMode() { holdResponse = true }
    func waitUntilHeld() async { while continuation == nil { await Task.yield() } }
    func releaseMode() { continuation?.resume(); continuation = nil }
    func feedback(side: Side, input: PersonalComfortFeedback) async throws -> PersonalComfortStatus { try await delegate.feedback(side: side, input: input) }
    func reports(side: Side) async throws -> ComfortNightList { try await delegate.reports(side: side) }
    func report(side: Side, id: String, after: Int?) async throws -> ComfortNightDetail { try await delegate.report(side: side, id: id, after: after) }
    func review(_ input: ComfortReviewInput) async throws -> ComfortNightReview { try await delegate.review(input) }
}

private final class ComfortModeProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); guard count > 0 else { break }; data.append(contentsOf: bytes.prefix(count)) }
            }
            let fields = try JSONSerialization.jsonObject(with: data) as! [String: String]
            let valid = request.url?.path == "/api/v1/comfort/mode" && request.httpMethod == "POST" && fields == ["side": "left", "mode": "off"]
            let source = try PersonalComfortExample.load().status
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: valid ? 200 : 422, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONEncoder().encode(source)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
