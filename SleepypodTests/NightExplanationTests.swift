import XCTest
@testable import Sleepypod

@MainActor final class NightExplanationTests: XCTestCase {
    func testSourceGeneratedCasesPreserveDSTAndEvidence() throws {
        let fixture = try NightExplanationExample.load()
        XCTAssertTrue(fixture.synthetic); XCTAssertEqual(fixture.sourceCommit.count, 40)
        for report in fixture.cases.values { try report.validate() }
        let spring = try XCTUnwrap(fixture.cases["spring"]), autumn = try XCTUnwrap(fixture.cases["autumn"])
        XCTAssertEqual(spring.end - spring.start, 23 * 3_600_000)
        XCTAssertEqual(autumn.end - autumn.start, 25 * 3_600_000)
        let report = try example()
        XCTAssertEqual(report.events.first?.kind, .acknowledged)
        XCTAssertEqual(report.events[1].kind, .withheld); XCTAssertEqual(report.events[1].count, 3)
        XCTAssertEqual(report.room.first?.timeBasis, "cached"); XCTAssertNil(report.room.first?.measuredAt)
        XCTAssertFalse(report.events.first?.detail.contains("physically verified") ?? true)
        let generated = Date(timeIntervalSince1970: report.generatedAt / 1000)
        XCTAssertTrue(report.current(at: generated)); XCTAssertFalse(report.current(at: generated.addingTimeInterval(-1)))
        XCTAssertFalse(report.current(at: generated.addingTimeInterval(300)))
    }
    func testMalformedIdentityClocksValuesAndBoundsAreRejected() throws {
        for field in ["apiVersion", "timeZone", "attribution", "wakeDate", "start", "observedThrough", "roomSampleIntervalMs", "sources", "events", "thermal"] {
            let report = try modified { object in
                switch field {
                case "apiVersion": object[field] = 2
                case "timeZone": object[field] = "Invalid/Zone"
                case "attribution": object[field] = "luca"
                case "wakeDate": object[field] = "2026-02-30"
                case "start": object[field] = (try XCTUnwrap(object["end"] as? Double)) + 1
                case "observedThrough": object[field] = (try XCTUnwrap(object["generatedAt"] as? Double)) + 1
                case "roomSampleIntervalMs": object[field] = 1
                case "sources": object[field] = Array(repeating: try XCTUnwrap((object[field] as? [[String: Any]])?.first), count: 5)
                case "events": object[field] = Array(repeating: try XCTUnwrap((object[field] as? [[String: Any]])?.first), count: 2)
                case "thermal":
                    var rows = try XCTUnwrap(object[field] as? [[String: Any]])
                    var first = try XCTUnwrap(rows.first); first["reportedF"] = 1000
                    rows[0] = first; object[field] = rows
                default: break
                }
            }
            XCTAssertThrowsError(try report.validate(), field)
        }
    }
    func testChartDoesNotJoinMissingOrReorderedDataAndOffTargets() {
        let samples: [NightExplanation.Thermal] = [
            .init(id: 1, at: 1000, powered: true, targetF: 70, reportedF: 72),
            .init(id: 2, at: 61_000, powered: true, targetF: 70, reportedF: 71),
            .init(id: 3, at: 181_000, powered: true, targetF: 70, reportedF: 70),
            .init(id: 4, at: 241_000, powered: false, targetF: 70, reportedF: nil),
            .init(id: 5, at: 301_000, powered: true, targetF: 70, reportedF: 70),
            .init(id: 6, at: 301_000, powered: true, targetF: 70, reportedF: 70)
        ]
        for target in [false, true] {
            let points = NightTemperatureSeries.points(samples, target: target, celsius: false)
            XCTAssertEqual(points.map(\.id), [1, 2, 3, 5, 6])
            XCTAssertEqual(points.map(\.segment), [0, 0, 1, 2, 3])
        }
        XCTAssertEqual(NightTemperatureSeries.points(samples, target: true, celsius: true)[0].value, 21.1111, accuracy: 0.001)
    }
    func testFailureAndOwnerChangesWithdrawHistoryImmediately() async throws {
        var owner: [String]? = ["first"]
        let report = try example(), client = NightFixtureClient(report: try example())
        let model = NightExplanationWorkspace(currentOwner: { owner })
        let now = Date(timeIntervalSince1970: report.generatedAt / 1000)
        model.configure(client: client, side: .left, wakeDate: report.wakeDate); await model.refresh()
        XCTAssertNotNil(model.report(at: now))
        await client.fail(); await model.refresh(); XCTAssertNil(model.report(at: now)); XCTAssertNotNil(model.error)
        model.configure(client: NightFixtureClient(report: report), side: .left, wakeDate: report.wakeDate); await model.refresh()
        owner = ["second"]; XCTAssertNil(model.report(at: now))
        owner = nil; await model.refresh(); XCTAssertNil(model.report(at: now))
    }
    func testWrongSideAndWrongDateRepliesCannotBeDisplayed() async throws {
        let report = try example(), now = Date(timeIntervalSince1970: try example().generatedAt / 1000)
        for (side, date) in [(Side.right, report.wakeDate), (.left, "2026-11-09")] {
            let model = NightExplanationWorkspace(currentOwner: { ["owner"] })
            model.configure(client: NightFixtureClient(report: report), side: side, wakeDate: date); await model.refresh()
            XCTAssertNil(model.report(at: now)); XCTAssertNotNil(model.error)
        }
    }
    func testLateReadCannotCrossMorningConnectionOrCancellation() async throws {
        for change in ["date", "owner", "cancel"] {
            let report = try example(), client = DelayedNightFixtureClient()
            var owner: [String]? = ["first"]
            let model = NightExplanationWorkspace(currentOwner: { owner })
            model.configure(client: client, side: .left, wakeDate: report.wakeDate)
            let operation = Task { await model.refresh() }; await client.waitUntilStarted()
            if change == "date" { model.configure(client: client, side: .left, wakeDate: "2026-11-09") }
            else if change == "owner" { owner = ["second"] }
            else { operation.cancel() }
            await client.finish(report); await operation.value
            XCTAssertNil(model.report(at: Date(timeIntervalSince1970: report.generatedAt / 1000))); XCTAssertFalse(model.loading)
        }
    }
    func testRESTIsReadOnlyAndUsesExplicitPhysicalSideAndMorning() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [NightFixtureProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let transport = CoreRESTClient(endpoint: try XCTUnwrap(URL(string: "http://127.0.0.1:3000")), session: session)
        try await CoreNightExplanationClient(transport: transport).read(side: .left, wakeDate: "2026-11-10").validate()
    }
    func testDemoUsesSyntheticJournalsAndRejectsOtherDates() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let report = try DemoNightExplanationClient().read(side: .right, wakeDate: NightExplanation.dateKey(.now, timeZone: zone))
        try report.validate(); XCTAssertEqual(report.side, .right); XCTAssertTrue(report.current(at: .now))
        XCTAssertThrowsError(try DemoNightExplanationClient().read(side: .left, wakeDate: "2000-01-01"))
    }
    private func example() throws -> NightExplanation { try XCTUnwrap(NightExplanationExample.load().cases["normal"]) }
    private func modified(_ change: (inout [String: Any]) throws -> Void) throws -> NightExplanation {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(example())) as? [String: Any])
        try change(&object)
        return try JSONDecoder().decode(NightExplanation.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
private actor NightFixtureClient: NightExplanationClient {
    let report: NightExplanation
    private var failed = false
    init(report: NightExplanation) { self.report = report }
    func fail() { failed = true }
    func read(side: Side, wakeDate: String) throws -> NightExplanation {
        if failed { throw URLError(.notConnectedToInternet) }; return report
    }
}
private actor DelayedNightFixtureClient: NightExplanationClient {
    private var continuation: CheckedContinuation<NightExplanation, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func read(side: Side, wakeDate: String) async -> NightExplanation {
        await withCheckedContinuation { continuation in self.continuation = continuation; waiter?.resume(); waiter = nil }
    }
    func waitUntilStarted() async { if continuation != nil { return }; await withCheckedContinuation { waiter = $0 } }
    func finish(_ report: NightExplanation) { continuation?.resume(returning: report); continuation = nil }
}
private final class NightFixtureProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.path, "/api/v1/device/night-explanation"); XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value) }), ["side": "left", "wakeDate": "2026-11-10"])
        do {
            let report = try XCTUnwrap(NightExplanationExample.load().cases["normal"])
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONEncoder().encode(report)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
