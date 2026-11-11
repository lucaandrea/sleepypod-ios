import XCTest
@testable import Sleepypod

@MainActor final class ComfortLimitTests: XCTestCase {
    private func fixture(revision: Int = 1, side: Side = .left) -> ComfortLimitPage {
        .init(apiVersion: 1, side: side, sourceSide: side, revision: revision,
              config: .init(enabled: true, minF: 68, maxF: 72), wake: nil, wakeAvailable: true)
    }
    func testConfigurationRejectsUnorderedWideAndOutOfBoundsRanges() {
        for range in [(73, 68), (55, 80), (54, 60), (105, 111)] {
            XCTAssertFalse(ComfortLimitConfiguration(enabled: true, minF: range.0, maxF: range.1).isValid)
        }
        XCTAssertTrue(ComfortLimitConfiguration(enabled: true, minF: 70, maxF: 70).isValid)
    }
    func testUnsupportedVersionWrongSideAndInvalidWakeCannotBecomeConfirmed() throws {
        try fixture().validate(for: .left)
        XCTAssertThrowsError(try fixture(side: .right).validate(for: .left))
        let invalid = ComfortLimitPage(apiVersion: 2, side: .left, sourceSide: .left, revision: 1,
            config: fixture().config, wake: nil, wakeAvailable: true)
        XCTAssertThrowsError(try invalid.validate(for: .left))
        let wrongWake = ComfortLimitPage(apiVersion: 1, side: .left, sourceSide: .left, revision: 1,
            config: fixture().config, wake: .init(startsAt: 2000, alarmAt: 1000, targetF: 105, timeZone: "UTC"), wakeAvailable: true)
        XCTAssertThrowsError(try wrongWake.validate(for: .left))
    }
    func testConfigurationAndNewOwnershipMetadataDecodeWithoutChangingOldStatus() throws {
        let page = try JSONDecoder().decode(ComfortLimitPage.self, from: JSONEncoder().encode(fixture()))
        XCTAssertEqual(page, fixture())
        let previous = try JSONDecoder().decode(TemperatureControlStatus.self, from: Data("{\"source\":\"schedule\"}".utf8))
        XCTAssertNil(previous.comfortLimit)
        let limited = ComfortLimitDecision(state: "limited", requestedF: 85, targetF: 72, minF: 68, maxF: 72, revision: 1, wakeUntil: nil)
        XCTAssertTrue(limited.explanation?.contains("85°F") == true)
        XCTAssertTrue(limited.explanation?.contains("72°F") == true)
    }
    func testSaveUsesConfirmedSideAndRevisionExactlyOnce() async throws {
        let client = ComfortLimitFixtureClient(page: fixture())
        let model = ComfortLimitWorkspace(currentOwner: { ["owner"] })
        model.configure(side: .left, client: client)
        await model.refresh()
        let original = try XCTUnwrap(model.page)
        let changed = ComfortLimitConfiguration(enabled: true, minF: 69, maxF: 73)
        let saved = await model.save(changed, original: original)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.page?.config, changed)
        XCTAssertEqual(model.page?.revision, 2)
        let requests = await client.requests
        XCTAssertEqual(requests, [.init(side: .left, expectedSourceSide: .left, expectedRevision: 1, config: changed)])
        let stale = await model.save(changed, original: original)
        XCTAssertFalse(stale)
        let count = await client.requests.count
        XCTAssertEqual(count, 1)
    }
    func testFailedSaveWithdrawsConfirmationAndNeverRetries() async throws {
        let client = ComfortLimitFixtureClient(page: fixture())
        let model = ComfortLimitWorkspace(currentOwner: { ["owner"] })
        model.configure(side: .left, client: client)
        await model.refresh()
        let original = try XCTUnwrap(model.page)
        await client.fail()
        let saved = await model.save(original.config, original: original)
        XCTAssertFalse(saved)
        XCTAssertNil(model.page)
        XCTAssertTrue(model.error?.contains("No retry was queued") == true)
        await model.refresh()
        let count = await client.requests.count
        XCTAssertEqual(count, 1)
    }
    func testOwnerChangeHidesSettingsAndPreventsMutationBeforeRefresh() async throws {
        var owner: [String]? = ["first"]
        let client = ComfortLimitFixtureClient(page: fixture())
        let model = ComfortLimitWorkspace(currentOwner: { owner })
        model.configure(side: .left, client: client)
        await model.refresh()
        let original = try XCTUnwrap(model.page)
        owner = ["second"]
        XCTAssertNil(model.page)
        let saved = await model.save(original.config, original: original)
        XCTAssertFalse(saved)
        let count = await client.requests.count
        XCTAssertEqual(count, 0)
    }
    func testRESTContractUsesVersionedRouteSideAndRevision() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ComfortLimitTransportProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = CoreComfortLimitClient(transport: .init(endpoint: URL(string: "https://comfort-limit.invalid")!, session: session))
        let page = try await client.read(side: .right)
        XCTAssertEqual(page.sourceSide, .left)
        let saved = try await client.save(.init(side: .right, expectedSourceSide: .left, expectedRevision: 3,
            config: .init(enabled: true, minF: 69, maxF: 72)))
        XCTAssertEqual(saved.revision, 4)
        XCTAssertEqual(saved.config.minF, 69)
    }
    func testInvalidatingHidesTheConfirmedConfiguration() async {
        let model = ComfortLimitWorkspace(currentOwner: { ["owner"] })
        model.configure(side: .left, client: ComfortLimitFixtureClient(page: fixture()))
        await model.refresh()
        XCTAssertNotNil(model.page)
        model.invalidate()
        XCTAssertNil(model.page)
    }
}

private actor ComfortLimitFixtureClient: ComfortLimitClient {
    var page: ComfortLimitPage
    var requests: [ComfortLimitWrite] = []
    var failing = false
    init(page: ComfortLimitPage) { self.page = page }
    func fail() { failing = true }
    func read(side: Side) throws -> ComfortLimitPage {
        if failing { throw APIError.noBaseURL }
        return page
    }
    func save(_ change: ComfortLimitWrite) throws -> ComfortLimitPage {
        requests.append(change)
        if failing { throw APIError.noBaseURL }
        page = .init(apiVersion: 1, side: change.side, sourceSide: change.expectedSourceSide,
            revision: change.expectedRevision + 1, config: change.config, wake: nil, wakeAvailable: true)
        return page
    }
}

private final class ComfortLimitTransportProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "comfort-limit.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        do {
            XCTAssertEqual(url.path, "/api/v1/temperature/comfort-limit")
            let updated = request.httpMethod == "PUT"
            if updated {
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        data.append(contentsOf: buffer.prefix(count))
                    }
                }
                let change = try JSONDecoder().decode(ComfortLimitWrite.self, from: data)
                XCTAssertEqual(change, .init(side: .right, expectedSourceSide: .left, expectedRevision: 3,
                    config: .init(enabled: true, minF: 69, maxF: 72)))
                XCTAssertNil(url.query)
            } else {
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [.init(name: "side", value: "right")])
            }
            let page = ComfortLimitPage(apiVersion: 1, side: .right, sourceSide: .left, revision: updated ? 4 : 3,
                config: .init(enabled: true, minF: updated ? 69 : 68, maxF: 72), wake: nil, wakeAvailable: true)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json", "Cache-Control": "no-store"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONEncoder().encode(page))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
