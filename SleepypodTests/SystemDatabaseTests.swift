import XCTest
@testable import Sleepypod

@MainActor final class SystemDatabaseTests: XCTestCase {
    func testOverviewRetainsMissingBackupAndIntegrityTimes() throws {
        let overview = try DemoSystemDatabaseClient().overview(fresh: false)
        XCTAssertEqual(overview.databases.count, 2)
        XCTAssertNil(overview.lastBackupAt)
        XCTAssertNil(overview.databases[0].integrity.manual)
        XCTAssertEqual(overview.totalBytes, 7_697_152)
        XCTAssertEqual(overview.databases[0].migrations.note, "0012_demo")
    }
    func testProjectionCapsRetainedTablesAndDoesNotCountUpdatesAsInserts() throws {
        let retained = table(rows: 100, bytes: 1000, rows24h: 50, retention: .init(days: 3, by: "test"))
        XCTAssertEqual(retained.dailyGrowth, 500)
        XCTAssertEqual(retained.projectedBytes(after: 1), 1500)
        XCTAssertEqual(retained.projectedBytes(after: 100), 1500)
        let updated = table(rows: 100, bytes: 1000, rows24h: 50, timeColumn: "updated_at")
        XCTAssertEqual(updated.dailyGrowth, 0)
        XCTAssertEqual(updated.projectedBytes(after: 100), 1000)
        let unpruned = table(rows: 100, bytes: 1000, rows24h: 50)
        let outlook = SystemDatabaseOutlook(tables: [unpruned], availableBytes: 1000)
        XCTAssertEqual(outlook.fillDays, 2)
        XCTAssertNil(SystemDatabaseOutlook(tables: [unpruned], availableBytes: nil).fillDays)
        XCTAssertNil(SystemDatabaseOutlook(tables: [unpruned], availableBytes: nil).availableBytes)
    }
    func testMissingHoursRequireAnOccupiedVitalsHour() {
        let vitals = table(rows: 1, bytes: 100, rows24h: 1)
        XCTAssertTrue(vitals.missingHour(0, occupied: [0]))
        XCTAssertFalse(vitals.missingHour(1, occupied: [1]))
        XCTAssertFalse(vitals.missingHour(0, occupied: []))
        XCTAssertFalse(vitals.missingHour(20, occupied: [20]))
    }
    func testRowsKeepNullNumericAndTextValuesAndEscapeCSV() throws {
        let data = Data(#"{"columns":["value","side","secret"],"timeColumn":null,"total":1,"rows":[[-4,"=SUM(1,2)",null]]}"#.utf8)
        let result = try JSONDecoder().decode(SystemDatabaseRows.self, from: data)
        XCTAssertEqual(result.rows[0], [.number(-4), .text("=SUM(1,2)"), .null])
        XCTAssertEqual(result.csv, "\"value\",\"side\",\"secret\"\r\n-4.0,\"'=SUM(1,2)\",")
        XCTAssertEqual(SystemDatabaseRows.csvText("a,\"b\"\nline"), "\"a,\"\"b\"\"\nline\"")
        XCTAssertEqual(SystemDatabaseRows.csvText("\t+formula"), "\"'\t+formula\"")
    }
    func testMalformedFilterIsRejectedAndEmptyStringEqualityIsValid() {
        XCTAssertNotNil(SystemDatabaseQuery(database: .sleepypod, table: "settings", column: "name").validation)
        XCTAssertNotNil(SystemDatabaseQuery(database: .sleepypod, table: "settings", column: "name", value: String(repeating: "x", count: 257)).validation)
        XCTAssertNotNil(SystemDatabaseQuery(database: .sleepypod, table: "settings", offset: -1).validation)
        XCTAssertNil(SystemDatabaseQuery(database: .sleepypod, table: "settings", column: "name", value: "").validation)
    }
    func testTransportPreservesExactFilterAndPaginationAndOnlyUsesReadRoute() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SystemDatabaseProtocol.self]
        let client = CoreSystemDatabaseClient(transport: .init(endpoint: URL(string: "https://database-test.invalid")!, session: .init(configuration: configuration)))
        let query = SystemDatabaseQuery(database: .biometrics, table: "vitals", column: "side", value: "left & \"right\"", offset: 10, limit: 10)
        let result = try await client.rows(query)
        XCTAssertEqual(result.total, 0)
        do { _ = try await client.rows(.init(database: .sleepypod, table: "")); XCTFail("Invalid query must not reach transport") } catch { XCTAssertTrue(error.localizedDescription.contains("table")) }
    }
    func testDemoPaginationAndFilterUseTheAppliedQuery() async throws {
        let model = SystemDatabaseRowsWorkspace(query: .init(database: .biometrics, table: "vitals"), client: DemoSystemDatabaseClient())
        await model.load(); XCTAssertEqual(model.result?.rows.count, 10); XCTAssertEqual(model.result?.total, 23)
        var query = model.query; query.offset = 10
        await model.load(query); XCTAssertEqual(model.result?.rows.first?.first, .number(13))
        query.offset = 0; query.column = "side"; query.value = "left"
        await model.load(query); XCTAssertEqual(model.result?.total, 11)
        XCTAssertTrue(model.result?.rows.allSatisfy { $0[1] == .text("left") } == true)
    }
    func testRunOnceCancellationRequiresExplicitControllerSuccess() async throws {
        for outcome in ["true", "false", "missing"] {
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RunOnceCancellationProtocol.self]
            let session = URLSession(configuration: configuration)
            let client = SleepypodCoreClient(session: session, baseURL: URL(string: "https://cancel-\(outcome).invalid")!)
            do {
                try await client.cancelRunOnce(side: .right)
                XCTAssertEqual(outcome, "true", "An unconfirmed cancellation must stay visible")
            } catch {
                XCTAssertNotEqual(outcome, "true")
                XCTAssertTrue(error.localizedDescription.contains("did not confirm"))
            }
            session.invalidateAndCancel()
        }
    }
    func testLateResponseCannotReplaceNewFilter() async {
        let client = DelayedDatabaseClient()
        let model = SystemDatabaseRowsWorkspace(query: .init(database: .biometrics, table: "vitals"), client: client)
        let first = Task { await model.load() }
        await client.waitUntilPending()
        var query = model.query; query.column = "side"; query.value = "right"
        await model.load(query)
        XCTAssertEqual(model.result?.total, 2)
        await client.finishFirst(); await first.value
        XCTAssertEqual(model.result?.total, 2); XCTAssertEqual(model.query.value, "right")
        query.value = "fail"; await model.load(query)
        XCTAssertNil(model.result); XCTAssertNotNil(model.error)
    }
    private func table(rows: Int, bytes: Double, rows24h: Int, timeColumn: String = "timestamp", retention: SystemDatabase.Table.Retention? = nil) -> SystemDatabase.Table {
        .init(name: "vitals", rows: rows, bytes: bytes, timeColumn: timeColumn, timeInMs: false, lastWriteAt: nil, oldestAt: nil, hourly: [0, 1], rows24h: rows24h, retention: retention)
    }
}

private final class RunOnceCancellationProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasPrefix("cancel-") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(url.path, "/api/trpc/runOnce.cancel")
        let value = url.host == "cancel-true.invalid" ? #"{"success":true}"# : url.host == "cancel-false.invalid" ? #"{"success":false}"# : "{}"
        let body = "{\"result\":{\"data\":{\"json\":\(value)}}}"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor DelayedDatabaseClient: SystemDatabaseClient {
    private var continuation: CheckedContinuation<SystemDatabaseRows, Never>?
    func waitUntilPending() async { while continuation == nil { await Task.yield() } }
    func finishFirst() { continuation?.resume(returning: .init(columns: [], timeColumn: nil, rows: [], total: 100)); continuation = nil }
    func rows(_ query: SystemDatabaseQuery) async throws -> SystemDatabaseRows {
        if query.column == nil { return await withCheckedContinuation { continuation = $0 } }
        if query.value == "fail" { throw APIError.serverError(message: "Controller unavailable") }
        return .init(columns: [], timeColumn: nil, rows: [], total: 2)
    }
    func overview(fresh: Bool) throws -> SystemDatabaseOverview { throw APIError.noBaseURL }
    func integrity() throws -> [String: SystemDatabase.IntegrityRun] { [:] }
    func backup(directory: URL) throws -> URL { throw APIError.noBaseURL }
}

private final class SystemDatabaseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "database-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        XCTAssertEqual(request.httpMethod, "GET"); XCTAssertEqual(url.path, "/api/system/databases/rows")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items, ["db": "biometrics", "table": "vitals", "column": "side", "value": "left & \"right\"", "offset": "10", "limit": "10"])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"columns":[],"timeColumn":null,"total":0,"rows":[]}"#.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
