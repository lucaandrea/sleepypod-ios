import XCTest
@testable import Sleepypod

final class CoreHardwareStatusTests: XCTestCase {
    func testFailedOptionalEndpointsCannotReportHealthyHardware() async throws {
        let status = try await read("missing")
        XCTAssertFalse(status.podSocket.status.isHealthy)
        XCTAssertFalse(status.podSocketMonitor.status.isHealthy)
        XCTAssertFalse(status.logger.status.isHealthy)
        XCTAssertEqual(status.podSocket.message, "Hardware status unavailable")
        XCTAssertEqual(status.podSocketMonitor.message, "DAC monitor status unavailable")
        XCTAssertEqual(status.logger.message, "Wi-Fi status unavailable")
        XCTAssertTrue(status.database.status.isHealthy)
    }
    func testMalformedAndUnrecognizedHardwareReadingsRemainUnknown() async throws {
        let status = try await read("malformed")
        XCTAssertFalse(status.podSocket.status.isHealthy)
        XCTAssertFalse(status.podSocketMonitor.status.isHealthy)
        XCTAssertFalse(status.logger.status.isHealthy)
    }
    func testSupportedMonitorStatesAndMissingMeasurements() async throws {
        for state in ["running", "polling", "connected"] {
            let status = try await read(state)
            XCTAssertTrue(status.podSocket.status.isHealthy)
            XCTAssertTrue(status.podSocketMonitor.status.isHealthy)
            XCTAssertTrue(status.logger.status.isHealthy)
            XCTAssertEqual(status.podSocket.message, "Latency unavailable")
            XCTAssertEqual(status.logger.message, "Connected · signal unavailable")
        }
    }
    func testRealHardwareFailureAndDisconnectedWifiRemainVisible() async throws {
        let status = try await read("failed")
        XCTAssertEqual(status.podSocket.status, .failed)
        XCTAssertEqual(status.podSocket.message, "Socket unavailable")
        XCTAssertEqual(status.podSocketMonitor.status, .failed)
        XCTAssertEqual(status.logger.status, .failed)
        XCTAssertEqual(status.logger.message, "Disconnected")
    }
    private func read(_ variant: String) async throws -> ServerStatus {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoreHardwareStatusProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await SleepypodCoreClient(session: session, baseURL: URL(string: "https://\(variant).hardware-status.invalid")!).getServerStatus()
    }
}
private final class CoreHardwareStatusProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".hardware-status.invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let variant = url.host?.components(separatedBy: ".").first ?? "missing"
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(url.path, "/api/trpc/health.system,health.scheduler,health.hardware,health.dacMonitor,system.wifiStatus")
        let healthySystem: [String: Any] = ["status": "ok", "database": ["status": "ok", "latencyMs": 2], "scheduler": ["enabled": true, "jobCount": 3]]
        let scheduler: [String: Any] = ["enabled": true, "healthy": true, "jobCounts": ["total": 3, "temperature": 1, "powerOn": 1, "powerOff": 1, "alarm": 0, "prime": 0, "reboot": 0]]
        let wrap: ([String: Any]) -> [String: Any] = { ["result": ["data": ["json": $0]]] }
        let optional: [[String: Any]]
        switch variant {
        case "missing": optional = Array(repeating: ["error": ["json": ["message": "Unavailable"]]], count: 3)
        case "malformed": optional = [wrap(["unexpected": true]), wrap(["status": "future_state"]), wrap(["connected": "invalid"])]
        case "failed": optional = [wrap(["status": "error", "error": "Socket unavailable"]), wrap(["status": "disconnected"]), wrap(["connected": false])]
        default: optional = [wrap(["status": "ok"]), wrap(["status": variant]), wrap(["connected": true])]
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: [wrap(healthySystem), wrap(scheduler)] + optional)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
