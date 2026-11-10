import XCTest
@testable import Sleepypod

@MainActor final class RecordingReadinessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_348_000)

    func testReadyRequiresEveryCurrentCheckAndExpiresWithUnderlyingEvidence() throws {
        let report = fixture()
        try report.validate()
        XCTAssertEqual(report.status(at: now), .ready)
        XCTAssertEqual(report.status(at: now.addingTimeInterval(20)), .unavailable)
        XCTAssertEqual(report.status(at: now.addingTimeInterval(-1)), .unavailable)
    }
    func testUnknownAndAttentionAreNeverReadyEvenWhenServerClaimsReady() {
        XCTAssertEqual(fixture(checkState: "unknown").status(at: now), .unknown)
        XCTAssertEqual(fixture(checkState: "future-kind").status(at: now), .unknown)
        XCTAssertEqual(fixture(checkState: "attention").status(at: now), .attention)
    }
    func testOldFutureAndMissingObservationsCannotEstablishReadiness() {
        for observation in [Optional(1_794_347_939_000.0), 1_794_348_001_000, nil] {
            let result = fixture(observation: observation)
            XCTAssertNotEqual(result.status(at: now), .ready)
        }
    }
    func testIncompleteDuplicateAndUnsupportedContractsAreRejected() {
        let base = fixture()
        for checks in [Array(base.checks.dropLast()), Array(repeating: base.checks[0], count: 8)] {
            let changed = RecordingReadiness(apiVersion: 1, generatedAt: base.generatedAt, expiresAt: base.expiresAt,
                state: "ready", summary: "fixture", checks: checks, historicalWindowHours: 24)
            XCTAssertThrowsError(try changed.validate())
            XCTAssertEqual(changed.status(at: now), .unavailable)
        }
        let future = RecordingReadiness(apiVersion: 2, generatedAt: base.generatedAt, expiresAt: base.expiresAt,
            state: "ready", summary: "fixture", checks: base.checks, historicalWindowHours: 24)
        XCTAssertThrowsError(try future.validate())
    }
    func testFutureOrExcessiveExpiryCannotRenewEvidence() {
        let base = fixture()
        let result = RecordingReadiness(apiVersion: 1, generatedAt: base.generatedAt, expiresAt: base.generatedAt + 61_000,
            state: "ready", summary: "fixture", checks: base.checks, historicalWindowHours: 24)
        XCTAssertThrowsError(try result.validate())
        XCTAssertEqual(result.status(at: now), .unavailable)
    }
    func testDecodingPreservesMillisecondsAndUnknownStates() throws {
        let report = fixture(checkState: "future-kind")
        let decoded = try JSONDecoder().decode(RecordingReadiness.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded, report)
        XCTAssertEqual(decoded.checks.first?.statusLabel, "Not verified")
    }
    func testFailedRefreshWithdrawsOldReadyStatus() async {
        let client = ReadinessFixtureClient(report: fixture())
        let model = RecordingReadinessWorkspace(currentOwner: { ["owner"] })
        model.configure(client: client)
        await model.refresh()
        XCTAssertEqual(model.report?.status(at: now), .ready)
        await client.fail()
        await model.refresh()
        XCTAssertNil(model.report)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.loading)
    }
    func testOwnerSwitchHidesExistingReportBeforeAnotherRequest() async {
        var owner: [String]? = ["first"]
        let model = RecordingReadinessWorkspace(currentOwner: { owner })
        model.configure(client: ReadinessFixtureClient(report: fixture()))
        await model.refresh()
        XCTAssertNotNil(model.report)
        owner = ["second"]
        XCTAssertNil(model.report)
        owner = nil
        await model.refresh()
        XCTAssertNil(model.report)
    }
    func testLateResultFromPreviousOwnerIsDiscarded() async {
        var owner: [String]? = ["first"]
        let client = DelayedReadinessClient()
        let model = RecordingReadinessWorkspace(currentOwner: { owner })
        model.configure(client: client)
        let operation = Task { await model.refresh() }
        await client.waitUntilStarted()
        owner = ["second"]
        await client.finish(fixture())
        await operation.value
        XCTAssertNil(model.report)
        XCTAssertFalse(model.loading)
    }
    func testInvalidatingDuringReadNeverRepopulatesCard() async {
        let client = DelayedReadinessClient()
        let model = RecordingReadinessWorkspace(currentOwner: { ["owner"] })
        model.configure(client: client)
        let operation = Task { await model.refresh() }
        await client.waitUntilStarted()
        model.invalidate()
        await client.finish(fixture())
        await operation.value
        XCTAssertNil(model.report)
        XCTAssertFalse(model.loading)
    }
    func testReadsUseTheAuthenticatedRESTRouteWithoutAnyMutation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReadinessFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = CoreRecordingReadinessClient(transport: .init(endpoint: URL(string: "https://recording.invalid")!, session: session))
        let report = try await client.read()
        try report.validate()
        XCTAssertEqual(report.state, "unknown")
    }

    private func fixture(checkState: String = "ok", observation: Double? = 1_794_348_000_000) -> RecordingReadiness {
        let timestamp = now.timeIntervalSince1970 * 1000
        let checks = RecordingReadiness.requiredChecks.sorted().map {
            RecordingReadiness.Check(id: $0, title: $0, state: checkState, detail: "fixture", nextStep: nil, observedAt: observation)
        }
        return .init(apiVersion: 1, generatedAt: timestamp, expiresAt: timestamp + 20_000,
                     state: "ready", summary: "fixture", checks: checks, historicalWindowHours: 24)
    }
}

private actor ReadinessFixtureClient: RecordingReadinessClient {
    let report: RecordingReadiness
    var failing = false
    init(report: RecordingReadiness) { self.report = report }
    func fail() { failing = true }
    func read() throws -> RecordingReadiness {
        if failing { throw APIError.noBaseURL }
        return report
    }
}
private actor DelayedReadinessClient: RecordingReadinessClient {
    private var continuation: CheckedContinuation<RecordingReadiness, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func read() async -> RecordingReadiness {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiter?.resume(); waiter = nil
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish(_ report: RecordingReadiness) { continuation?.resume(returning: report); continuation = nil }
}
private final class ReadinessFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        XCTAssertEqual(url.path, "/api/health/recording")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        let checks = RecordingReadiness.requiredChecks.sorted().map {
            RecordingReadiness.Check(id: $0, title: $0, state: "unknown", detail: "fixture", nextStep: nil, observedAt: nil)
        }
        let fixture = RecordingReadiness(apiVersion: 1, generatedAt: 1_794_348_000_000, expiresAt: 1_794_348_060_000,
            state: "unknown", summary: "fixture", checks: checks, historicalWindowHours: 24)
        do {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONEncoder().encode(fixture))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
