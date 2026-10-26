import XCTest
@testable import Sleepypod

@MainActor final class SystemLogTests: XCTestCase {
    func testJournalParsingPreservesTimezoneColonsAndRawExportText() {
        let raw = "2026-10-25T18:00:09-07:00 pod sleepypod[22]: Warning: delayed sample"
        let entry = SystemLogEntry(raw: raw, index: 0)
        XCTAssertEqual(entry.raw, raw); XCTAssertEqual(entry.time, "18:00:09")
        XCTAssertEqual(entry.service, "sleepypod"); XCTAssertEqual(entry.message, "Warning: delayed sample")
        XCTAssertEqual(entry.level, .warning)
    }
    func testUnknownLinesAndPriorityCeilingRemainVisible() {
        let raw = "stack trace without a journal prefix"
        let entry = SystemLogEntry(raw: raw, index: 0, floor: .error)
        XCTAssertEqual(entry.message, raw); XCTAssertEqual(entry.time, ""); XCTAssertEqual(entry.level, .error)
        XCTAssertEqual(SystemLogLevel.detected(in: "critical sensor failure", floor: .all), .error)
        XCTAssertEqual(SystemLogLevel.detected(in: "debug sample", floor: .info), .debug)
        XCTAssertNil(SystemLogLevel.all.priority); XCTAssertEqual(SystemLogLevel.error.priority, "err")
    }
    func testStructuredDisplayNeverChangesTheRawLog() {
        let raw = #"2026-10-25T18:00:00+0000 pod sleepypod[2]: values %7B%22left%22%3A72%7D"#
        let entry = SystemLogEntry(raw: raw, index: 0)
        XCTAssertEqual(entry.raw, raw); XCTAssertEqual(entry.message, "values")
        XCTAssertTrue(entry.json?.contains("\"left\" : 72") == true)
    }
    func testInvalidUnitsAndLineLimitsNeverReachTransport() async throws {
        let client = CoreSystemLogClient(transport: .init(endpoint: URL(string: "https://must-not-connect.invalid")!))
        for query in [SystemLogQuery(unit: "ssh.service"), .init(unit: "sleepypod.service;id"), .init(unit: "sleepypod.service", lines: 501)] {
            do { _ = try await client.page(query); XCTFail("Invalid query was accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("Choose")) }
        }
    }
    func testTransportUsesSourceInventoryAndExactReadOnlyQuery() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [LogFixtureProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let client = CoreSystemLogClient(transport: .init(endpoint: URL(string: "https://logs-test.invalid")!, session: session))
        let sources = try await client.sources(); XCTAssertEqual(sources.first?.name, "Environment")
        let page = try await client.page(.init(unit: "sleepypod-environment-monitor.service", lines: 500, level: .warning))
        XCTAssertEqual(page.lines, ["warning: fixture"]); XCTAssertEqual(page.nextCursor, "older")
    }
    func testSourceSelectionFilteringAndExportUseTheCurrentSnapshot() async {
        let model = SystemLogWorkspace(client: DemoSystemLogClient())
        await model.loadSources(); XCTAssertEqual(model.sources.count, 4)
        XCTAssertEqual(model.query.unit, "sleepypod.service")
        await model.load(); XCTAssertEqual(model.entries.count, 4)
        XCTAssertEqual(model.filtered(" STALE ").count, 1)
        XCTAssertTrue(model.export("stale").contains("[WARN]")); XCTAssertFalse(model.export("stale").contains("[INFO]"))
        model.setLevel(.warning); XCTAssertTrue(model.entries.isEmpty); XCTAssertNil(model.receivedAt)
        await model.load(); XCTAssertEqual(model.entries.count, 2)
        model.setUnit("sleepypod-environment-monitor.service"); await model.load()
        XCTAssertTrue(model.export("").contains("sleepypod-environment-monitor.service"))
    }
    func testLateLogResponseCannotReplaceAChangedSource() async {
        let client = DelayedLogClient()
        let model = SystemLogWorkspace(unit: "sleepypod.service", client: client)
        let original = Task { await model.load() }
        await client.waitUntilPending()
        model.setUnit("sleepypod-environment-monitor.service")
        XCTAssertTrue(model.entries.isEmpty)
        await model.load(); XCTAssertEqual(model.export(""), "current source")
        await client.finish(); await original.value
        XCTAssertEqual(model.export(""), "current source")
        model.setLevel(.error); await model.load()
        XCTAssertNotNil(model.error); XCTAssertTrue(model.entries.isEmpty)
    }
}

private actor DelayedLogClient: SystemLogClient {
    private var continuation: CheckedContinuation<SystemLogPage, Never>?
    func sources() -> [LogSource] { [] }
    func waitUntilPending() async { while continuation == nil { await Task.yield() } }
    func finish() { continuation?.resume(returning: .init(lines: ["old source"], nextCursor: nil)); continuation = nil }
    func page(_ query: SystemLogQuery) async throws -> SystemLogPage {
        if query.unit == "sleepypod.service" { return await withCheckedContinuation { continuation = $0 } }
        if query.level == .error { throw APIError.noBaseURL }
        return .init(lines: ["current source"], nextCursor: nil)
    }
}

private final class LogFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "logs-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        XCTAssertEqual(request.httpMethod, "GET")
        let body: String
        if url.path == "/api/system/log-sources" {
            body = #"{"sources":[{"unit":"sleepypod-environment-monitor.service","name":"Environment","active":false}]}"#
        } else {
            XCTAssertEqual(url.path, "/api/system/logs")
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query, ["unit": "sleepypod-environment-monitor.service", "lines": "500", "priority": "warning"])
            body = #"{"lines":["warning: fixture"],"nextCursor":"older"}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
