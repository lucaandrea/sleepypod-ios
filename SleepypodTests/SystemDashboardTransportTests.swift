import XCTest
@testable import Sleepypod

@MainActor final class SystemDashboardTransportTests: XCTestCase {
    func testRuntimeAndMaintenanceUseExactReadOnlyRoutes() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DashboardTransportProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = CoreSystemDashboardClient(transport: .init(endpoint: URL(string: "https://overview.invalid")!, session: session))
        let runtime = try await client.runtime()
        XCTAssertEqual(runtime.uptime, "2d 6h")
        XCTAssertEqual(runtime.sensorSource, "nats")
        XCTAssertNil(runtime.firstFrameMs)
        XCTAssertEqual(runtime.memory?.arrayBuffersBytes, 12_000)
        let maintenance = try await client.maintenance()
        XCTAssertNil(maintenance.reportsPumpSpeed)
        XCTAssertTrue(maintenance.needsPumpProtection)
        XCTAssertTrue(maintenance.needsPrime(at: .now))
    }
    func testInternetChangeRequiresMatchingControllerReadback() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DashboardTransportProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SleepypodCoreClient(session: session, baseURL: URL(string: "https://overview.invalid")!)
        do {
            try await client.setInternetAccess(blocked: true)
            XCTFail("Mismatched controller state must not confirm a change")
        } catch { XCTAssertTrue(error.localizedDescription.contains("does not match")) }
        try await client.setInternetAccess(blocked: false)
    }
    func testPrimeRequiresPositiveControllerAcknowledgement() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DashboardTransportProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            try await SleepypodCoreClient(session: session, baseURL: URL(string: "https://overview.invalid")!).startPriming()
            XCTFail("A negative acknowledgement must not be reported as priming")
        } catch { XCTAssertTrue(error.localizedDescription.contains("did not accept")) }
    }
    func testCoreSettingsPreserveSoloConfigurationForVisibleSides() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DashboardTransportProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let settings = try await SleepypodCoreClient(session: session, baseURL: URL(string: "https://overview.invalid")!).getSettings()
        XCTAssertEqual(settings.bedMode, "solo-right")
        XCTAssertEqual(settings.shownSides, [.right])
        XCTAssertEqual(settings.timeZone, "Pacific/Auckland")
    }
    func testVisibleSidesCombineConfigurationAndAwayWithoutChangingZones() async throws {
        var settings = try await MockClient().getSettings()
        settings.bedMode = "two"; settings.left.awayMode = false; settings.right.awayMode = false
        XCTAssertEqual(settings.shownSides, [.left, .right])
        settings.right.awayMode = true
        XCTAssertEqual(settings.shownSides, [.left])
        settings.left.awayMode = true
        XCTAssertEqual(settings.shownSides, [.left, .right])
        settings.bedMode = "solo-right"; settings.right.awayMode = false
        XCTAssertEqual(settings.shownSides, [.right])
        settings.bedMode = "solo-left"; settings.left.awayMode = false
        XCTAssertEqual(settings.shownSides, [.left])
    }
    func testModelNamesMatchCoreHardwareProfilesAndKeepUnknownRevisionsUnknown() async throws {
        var status = try await MockClient().getDeviceStatus()
        for (revision, name) in [("H00", "Pod 3"), ("I00", "Pod 4"), ("J00", "Pod 5"), ("H01", "Pod")] {
            status.hubVersion = revision
            XCTAssertEqual(status.podModelName, name)
        }
    }
}
private final class DashboardTransportProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "overview.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        XCTAssertEqual(request.httpMethod, (url.path.hasSuffix("device.startPriming") || url.path.hasSuffix("system.setInternetAccess")) ? "POST" : "GET")
        let json: String
        switch url.path {
        case "/api/health/performance":
            json = #"{"uptimeSeconds":195420,"rssBytes":1000000,"memory":{"heapTotalBytes":100000,"heapUsedBytes":50000,"externalBytes":20000,"arrayBuffersBytes":12000},"startup":[],"sensorSource":"nats","firstFrameMs":null,"eventLoop":{"meanMs":1,"p95Ms":2,"maxMs":3}}"#
        case "/api/health/maintenance":
            json = #"{"pumpStallProtectionEnabled":false,"reportsPumpSpeed":null,"primePodDaily":false,"primePodTime":null,"lastPrimeAt":null,"firstPrimeRecordedAt":null}"#
        case "/api/trpc/system.setInternetAccess":
            json = #"{"result":{"data":{"json":{"blocked":false}}}}"#
        case "/api/trpc/device.startPriming":
            json = #"{"result":{"data":{"json":{"success":false}}}}"#
        case "/api/trpc/settings.getAll":
            json = #"{"result":{"data":{"json":{"device":{"bedMode":"solo-right","timezone":"Pacific/Auckland"},"sides":{"left":{"name":"Left","awayMode":false},"right":{"name":"Right","awayMode":false}}}}}}"#
        default:
            XCTFail("Unexpected overview request \(url.path)")
            client?.urlProtocol(self, didFailWithError: APIError.noBaseURL)
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
