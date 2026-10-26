import XCTest
@testable import Sleepypod

@MainActor final class PumpAlertTests: XCTestCase {
    func testTransportReadsMaximumListAndDismissesOnlyReviewedIdentity() async throws {
        let client = transport()
        let alerts = try await client.list(includeAcknowledged: true)
        XCTAssertEqual(alerts.map(\.id), [123])
        XCTAssertEqual(alerts.first?.title, "Pump stall")
        XCTAssertNotNil(alerts.first?.date)
        XCTAssertNil(alerts.first?.flowrateCd)
        try await client.dismiss(id: 123)
    }
    func testNegativeAcknowledgementIsNotSuccess() async throws {
        do { try await transport().dismiss(id: 124); XCTFail("Expected rejected acknowledgement") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not confirm")) }
    }
    func testBulkDismissContinuesPastFailureAndReadsBackNewIncidents() async {
        let client = AlertFixture()
        let model = PumpAlertWorkspace(client: client)
        await model.load()
        let reviewed = model.alerts
        await client.failDismissal(id: 101)
        await model.dismiss(reviewed)
        let calls = await client.calls
        XCTAssertEqual(calls, [101, 102])
        XCTAssertEqual(model.alerts.map(\.id), [101, 103])
        XCTAssertNotNil(model.failures[101])
        XCTAssertTrue(model.result?.contains("1 dismissal confirmed") == true)
        XCTAssertFalse(calls.contains(103))
    }
    func testExpiredOrChangedReviewCannotDismiss() async {
        let client = AlertFixture()
        let model = PumpAlertWorkspace(client: client)
        let start = Date()
        await model.load(now: start)
        let reviewed = model.alerts
        await model.dismiss(reviewed, now: start.addingTimeInterval(91))
        let firstCalls = await client.calls
        XCTAssertTrue(firstCalls.isEmpty)
        await client.removeFirst()
        await model.load()
        await model.dismiss(reviewed)
        let secondCalls = await client.calls
        XCTAssertTrue(secondCalls.isEmpty)
    }
    func testFailedReloadRetainsDataButPreventsAnotherDismissal() async {
        let client = AlertFixture()
        let model = PumpAlertWorkspace(client: client)
        await model.load()
        await client.failRead()
        await model.dismiss([model.alerts[0]])
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.alerts.isEmpty)
        XCTAssertFalse(model.canDismiss())
    }
    func testAcknowledgedFilterIsAppliedOnlyAfterSuccessfulRead() async {
        let client = AlertFixture()
        let model = PumpAlertWorkspace(client: client)
        await model.load(includeAcknowledged: true)
        XCTAssertTrue(model.includesAcknowledged)
        await client.failRead()
        await model.load(includeAcknowledged: false)
        XCTAssertTrue(model.includesAcknowledged)
        XCTAssertFalse(model.canDismiss())
    }
    private func transport() -> CorePumpAlertClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PumpAlertProtocol.self]
        return .init(transport: .init(endpoint: URL(string: "https://pump-alerts.invalid")!, session: URLSession(configuration: configuration)))
    }
}
private actor AlertFixture: PumpAlertClient {
    private var values = [make(101), make(102)]
    private var rejected: Int?
    private var readFails = false
    private(set) var calls: [Int] = []
    func list(includeAcknowledged: Bool) throws -> [PumpAlert] {
        if readFails { throw APIError.noBaseURL }
        return values
    }
    func dismiss(id: Int) throws {
        calls.append(id)
        if rejected == id { throw APIError.serverError(message: "Cutoff still pending") }
        values.removeAll { $0.id == id }
        if !values.contains(where: { $0.id == 103 }) { values.append(Self.make(103)) }
    }
    func failDismissal(id: Int) { rejected = id }
    func failRead() { readFails = true }
    func removeFirst() { values.removeFirst() }
    private static func make(_ identifier: Int) -> PumpAlert {
        .init(id: identifier, timestamp: "2026-10-25T18:00:00.000Z", type: "stall_left", side: .left, rpm: 20, flowrateCd: nil, durationSeconds: 18, action: "power_off", restoreTargetTemperature: nil, restoreDurationSeconds: nil, acknowledgedAt: nil, dismissedAt: nil)
    }
}
private final class PumpAlertProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "pump-alerts.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let response: String
        if url.path == "/api/pump-alerts" {
            XCTAssertEqual(request.httpMethod, "GET")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }), ["limit": "500", "includeAcknowledged": "true"])
            response = #"[{"id":123,"timestamp":"2026-10-25T18:00:00.000Z","type":"stall_left","side":"left","rpm":20,"flowrateCd":null,"durationSeconds":18,"action":"power_off","restoreTargetTemperature":74,"restoreDurationSeconds":3600,"acknowledgedAt":null,"dismissedAt":null}]"#
        } else {
            XCTAssertEqual(url.path, "/api/pump-alerts/dismiss")
            XCTAssertEqual(request.httpMethod, "POST")
            let body: Data
            if let data = request.httpBody { body = data }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024), data = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; data.append(buffer, count: count)
                }
                body = data
            } else { body = Data() }
            let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Int]
            XCTAssertEqual(Set(payload?.keys.map { $0 } ?? []), ["id"])
            XCTAssertTrue([123, 124].contains(payload?["id"] ?? 0))
            response = payload?["id"] == 123 ? #"{"success":true}"# : #"{"success":false}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
