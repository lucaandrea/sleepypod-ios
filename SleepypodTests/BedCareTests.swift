import XCTest
@testable import Sleepypod

@MainActor final class BedCareTests: XCTestCase {
    func testSourceGeneratedStatesAndIndependentExpiry() throws {
        let fixture = try BedCareExample.load()
        XCTAssertTrue(fixture.synthetic); XCTAssertEqual(fixture.sourceCommit.count, 40)
        for report in fixture.cases.values { try report.validate() }
        let now = Date(timeIntervalSince1970: fixture.now / 1000)
        let report = try XCTUnwrap(fixture.cases["observed"])
        XCTAssertTrue(report.current(at: now))
        XCTAssertFalse(report.current(at: now.addingTimeInterval(-1)))
        XCTAssertFalse(report.current(at: now.addingTimeInterval(31)))
        let water = try XCTUnwrap(report.checks.first { $0.id == "water" })
        let backup = try XCTUnwrap(report.checks.first { $0.id == "backup" })
        XCTAssertFalse(water.current(at: now.addingTimeInterval(26)))
        XCTAssertTrue(backup.current(at: now.addingTimeInterval(26)))
        XCTAssertTrue(backup.detail.contains("not verified"))
        XCTAssertEqual(fixture.cases["attention"]?.checks.first?.state, "attention")
        XCTAssertEqual(fixture.cases["priming"]?.checks.first?.state, "busy")
        XCTAssertEqual(fixture.cases["protectionDisabled"]?.checks[1].state, "attention")
        XCTAssertEqual(fixture.cases["protectionUnknown"]?.checks[1].state, "unknown")
        XCTAssertTrue(try XCTUnwrap(fixture.cases["unknown"]).checks.allSatisfy { $0.state == "unknown" })
    }
    func testUnsupportedDuplicateAndInvalidTimesAreRejected() throws {
        let report = try example()
        let invalid = [
            BedCare(apiVersion: 2, generatedAt: report.generatedAt, checks: report.checks, lastExportAt: nil),
            BedCare(apiVersion: 1, generatedAt: report.generatedAt, checks: Array(repeating: report.checks[0], count: 5), lastExportAt: nil),
            BedCare(apiVersion: 1, generatedAt: .nan, checks: report.checks, lastExportAt: nil),
            BedCare(apiVersion: 1, generatedAt: report.generatedAt, checks: report.checks, lastExportAt: report.generatedAt + 1)
        ]
        for value in invalid { XCTAssertThrowsError(try value.validate()); XCTAssertFalse(value.current(at: .now)) }
    }
    func testExpiredRefillAndPrimingObservationsWithdrawTheirAdvice() throws {
        let fixture = try BedCareExample.load()
        let expired = Date(timeIntervalSince1970: fixture.now / 1000 + 31)
        for state in ["observed", "priming"] {
            let report = try XCTUnwrap(fixture.cases[state])
            let water = try XCTUnwrap(report.checks.first { $0.id == "water" })
            XCTAssertEqual(water.advice(current: true), water.nextStep)
            XCTAssertEqual(water.advice(current: report.current(at: expired) && water.current(at: expired)), "Reconnect and check again before acting on this observation.")
        }
    }
    func testFailureWithdrawsPreviousReportAndOwnerChangeHidesItImmediately() async throws {
        var owner: [String]? = ["first"]
        let client = CareFixtureClient(report: try example())
        let model = BedCareWorkspace(currentOwner: { owner })
        model.configure(client: client); await model.refresh()
        XCTAssertNotNil(model.report)
        await client.fail(); await model.refresh()
        XCTAssertNil(model.report); XCTAssertNotNil(model.error)
        model.configure(client: CareFixtureClient(report: try example())); await model.refresh()
        owner = ["second"]; XCTAssertNil(model.report)
        owner = nil; await model.refresh(); XCTAssertNil(model.report)
    }
    func testLateResponseCannotCrossConnectionChangeOrCancelledView() async throws {
        for invalidate in [false, true] {
            var owner: [String]? = ["first"]
            let client = DelayedCareClient()
            let model = BedCareWorkspace(currentOwner: { owner })
            model.configure(client: client)
            let operation = Task { await model.refresh() }
            await client.waitUntilStarted()
            if invalidate { model.invalidate() } else { owner = ["second"] }
            await client.finish(try example()); await operation.value
            XCTAssertNil(model.report); XCTAssertFalse(model.loading)
        }
    }
    func testRESTUsesOnlyTheReadRouteAndNoCommandPayload() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CareFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = CoreRESTClient(endpoint: try XCTUnwrap(URL(string: "http://127.0.0.1:3000")), session: session)
        let report = try await CoreBedCareClient(transport: transport).read()
        try report.validate()
    }
    func testDemoExplicitlyUsesSyntheticExamplesAndMovesAllDatesTogether() throws {
        let report = try DemoBedCareClient().read()
        try report.validate()
        XCTAssertTrue(report.current(at: .now))
        XCTAssertEqual(report.checks.first?.state, "attention")
        XCTAssertEqual(report.generatedAt - (report.checks.first?.observedAt ?? 0), 5_000)
        XCTAssertEqual(report.generatedAt - (report.lastExportAt ?? 0), 86_400_000)
    }
    private func example() throws -> BedCare { try XCTUnwrap(BedCareExample.load().cases["observed"]) }
}
private actor CareFixtureClient: BedCareClient {
    let report: BedCare
    var failed = false
    init(report: BedCare) { self.report = report }
    func fail() { failed = true }
    func read() throws -> BedCare { if failed { throw URLError(.notConnectedToInternet) }; return report }
}
private actor DelayedCareClient: BedCareClient {
    private var continuation: CheckedContinuation<BedCare, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func read() async -> BedCare {
        await withCheckedContinuation { continuation in
            self.continuation = continuation; waiter?.resume(); waiter = nil
        }
    }
    func waitUntilStarted() async { if continuation != nil { return }; await withCheckedContinuation { waiter = $0 } }
    func finish(_ report: BedCare) { continuation?.resume(returning: report); continuation = nil }
}
private final class CareFixtureProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.path, "/api/health/care")
        XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
        do {
            let fixture = try BedCareExample.load()
            let report = try XCTUnwrap(fixture.cases["unknown"])
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONEncoder().encode(report))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
