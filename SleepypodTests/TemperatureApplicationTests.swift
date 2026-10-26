import XCTest
@testable import Sleepypod

@MainActor final class TemperatureApplicationTests: XCTestCase {
    func testActualCoreFixtureAndPaginationKeepOutcomesSeparate() throws {
        let fixtures = try applicationFixtures()
        XCTAssertEqual(fixtures.count, 7)
        for value in fixtures.values { try value.validate(side: value.side) }
        let first = fixtures["firstPage"]!, next = fixtures["secondPage"]!
        try next.validate(side: .left, before: first.nextBeforeId)
        XCTAssertEqual(first.items.count + next.items.count, 53)
        XCTAssertTrue(Set(first.items.map(\.id)).isDisjoint(with: next.items.map(\.id)))
        XCTAssertEqual(fixtures["attempting"]!.items[0].label, "Unconfirmed")
        XCTAssertEqual(fixtures["unknown"]!.items[0].label, "Unconfirmed")
        XCTAssertTrue(fixtures["acknowledged"]!.items[0].label.contains("physically unverified"))
        XCTAssertTrue(fixtures["otherSide"]!.items.isEmpty)
    }
    func testWrongSideBadCursorAndMalformedAcknowledgmentsFail() throws {
        let fixture = try applicationFixtures()["firstPage"]!
        XCTAssertThrowsError(try fixture.validate(side: .right))
        XCTAssertThrowsError(try fixture.validate(side: .left, before: fixture.items[0].id))
        let data = try JSONEncoder().encode(fixture)
        for mutation in ["target", "ack", "time", "duplicate", "cursor", "source"] {
            var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            var items = object["items"] as! [[String: Any]]
            switch mutation {
            case "target": items[0]["targetF"] = 200
            case "ack": items[0]["acknowledgment"] = "physically_verified"
            case "time": items[0]["finishedAt"] = 0
            case "duplicate": items[1] = items[0]
            case "cursor": object["nextBeforeId"] = 1
            default: items[0]["source"] = "untrusted"
            }
            object["items"] = items
            let altered = try JSONDecoder().decode(TemperatureApplicationPage.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try altered.validate(side: .left), mutation)
        }
    }
    func testPagedFailureKeepsPriorRowsAndCursorWithoutAutomaticRetry() async throws {
        let client = ApplicationPageProbe(), workspace = TemperatureApplicationWorkspace(client: { client }, owner: { ["owner"] })
        await workspace.reload(side: .left)
        XCTAssertEqual(workspace.items.count, 50)
        await client.failNext()
        await workspace.more()
        XCTAssertEqual(workspace.items.count, 50); XCTAssertEqual(workspace.nextBeforeId, 4); XCTAssertNotNil(workspace.error)
        let attempts = await client.count(); XCTAssertEqual(attempts, 2)
        await workspace.more()
        XCTAssertEqual(workspace.items.count, 53); XCTAssertNil(workspace.nextBeforeId); XCTAssertNil(workspace.error)
        await workspace.reload(side: .right)
        XCTAssertTrue(workspace.items.isEmpty); XCTAssertNil(workspace.error)
    }
    func testOwnerChangeCancellationAndInvalidationDiscardLatePages() async throws {
        for mode in ["owner", "cancel", "invalidate"] {
            let client = ApplicationPageProbe(), owner = ApplicationOwner()
            let workspace = TemperatureApplicationWorkspace(client: { client }, owner: { owner.value })
            await client.hold()
            let operation = Task { await workspace.reload(side: .left) }
            await client.waitHeld()
            switch mode { case "owner": owner.value = ["other"]; case "cancel": operation.cancel(); default: workspace.invalidate() }
            await client.release(); await operation.value
            XCTAssertTrue(workspace.items.isEmpty); XCTAssertNil(workspace.generatedAt); XCTAssertFalse(workspace.loading)
        }
    }
    func testTransportIsStrictlyReadOnlyAndUsesExactSideAndCursor() async throws {
        let transport = transport("history-contract.invalid"); defer { transport.session.invalidateAndCancel() }
        let client = CoreTemperatureApplicationClient(transport: transport)
        try await client.available()
        let page = try await client.read(side: .left, before: nil)
        let next = try await client.read(side: .left, before: page.nextBeforeId)
        XCTAssertEqual(next.items.count, 3)
        let other = try await client.read(side: .right, before: nil)
        XCTAssertTrue(other.items.isEmpty)
    }
    func testOlderCapabilitiesAndHTTPFailureStayUnavailableInsteadOfEmpty() async throws {
        for host in ["history-older.invalid", "history-redirect.invalid", "history-key.invalid", "history-large.invalid"] {
            let transport = transport(host); defer { transport.session.invalidateAndCancel() }
            do { try await CoreTemperatureApplicationClient(transport: transport).available(); XCTFail("Expected unavailable") }
            catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE")) }
        }
    }
    private func transport(_ host: String) -> CoreRESTClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ApplicationHistoryProtocol.self]
        return .init(endpoint: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration))
    }
}

private func applicationFixtures() throws -> [String: TemperatureApplicationPage] {
    struct Fixture: Decodable { let synthetic: Bool; let cases: [String: TemperatureApplicationPage] }
    let url = Bundle.main.url(forResource: "temperature-applications-example", withExtension: "json")!
    let value = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    guard value.synthetic else { throw TemperatureApplicationPage.invalid }; return value.cases
}
@MainActor private final class ApplicationOwner { var value = ["owner"] }
private actor ApplicationPageProbe: TemperatureApplicationClient {
    private var failing = false, holding = false, reads = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func available() async throws {}
    func failNext() { failing = true }
    func count() -> Int { reads }
    func hold() { holding = true }
    func waitHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    func read(side: Side, before: Int?) async throws -> TemperatureApplicationPage {
        reads += 1
        if holding { holding = false; await withCheckedContinuation { continuation = $0 } }
        if failing { failing = false; throw URLError(.notConnectedToInternet) }
        return try applicationFixtures()[side == .right ? "otherSide" : before == nil ? "firstPage" : "secondPage"]!
    }
}
private final class ApplicationHistoryProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = request.url!, host = url.host!
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            var valid = request.httpMethod == "GET" && request.httpBody == nil && request.httpBodyStream == nil && request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData
            var status = 200, data = Data()
            if host.contains("key") { status = 401; data = Data("PRIVATE".utf8) }
            else if host.contains("large") { data = Data(repeating: 32, count: 1_048_577) }
            else if url.path == "/api/v1/capabilities" {
                valid = valid && query.isEmpty
                var object: [String: Any] = ["apiVersion": 1]
                if !host.contains("older") {
                    object["endpoints"] = ["temperatureApplications": host.contains("redirect") ? "https://external.invalid" : "/api/v1/device/temperature/applications"]
                    object["features"] = ["temperatureApplicationHistory": ["implemented": true, "runtime": "ready"]]
                }
                data = try JSONSerialization.data(withJSONObject: object)
            } else if url.path == "/api/v1/device/temperature/applications" {
                valid = valid && [["side": "left"], ["side": "right"], ["side": "left", "beforeId": "4"]].contains(query)
                let name = query["side"] == "right" ? "otherSide" : query["beforeId"] == nil ? "firstPage" : "secondPage"
                data = try JSONEncoder().encode(applicationFixtures()[name]!)
            } else { valid = false }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: valid ? status : 422, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
