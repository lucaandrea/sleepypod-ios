import Foundation
import XCTest
import FreeSleepKit
@testable import Sleepypod

@MainActor
final class OwnerConnectionTests: XCTestCase {
    private let testOrigin = "https://owner-connection.invalid"
    private let testKey = "synthetic-key-for-isolated-transport-tests-only"
    private var savedDefaults: [String: Any] = [:]
    private let keys = ["podURL", "podIPAddress", "podNativeAPIPrefix", "podStreamURL", "apiBackend", "lastLiveBackend"]

    override func setUp() async throws {
        for key in keys { savedDefaults[key] = UserDefaults.standard.object(forKey: key); UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(testOrigin, forKey: "podURL")
    }
    override func tearDown() async throws {
        for key in keys { UserDefaults.standard.set(savedDefaults[key], forKey: key) }
    }
    func testBearerOnlyGoesToTheSavedOrigin() {
        let valid = OwnerConnection.authorize(URLRequest(url: URL(string: testOrigin + "/api/device/status")!), token: testKey)
        XCTAssertEqual(valid.value(forHTTPHeaderField: "Authorization"), "Bearer " + testKey)
        for origin in ["https://another.invalid", "http://owner-connection.invalid", "https://owner-connection.invalid:8443"] {
            let request = OwnerConnection.authorize(URLRequest(url: URL(string: origin + "/api/device/status")!), token: testKey)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }
    func testConnectionFormUsesTheActualDiscoveredAddressWithoutGrantingCredentialAuthority() {
        UserDefaults.standard.removeObject(forKey: "podURL")
        UserDefaults.standard.set("192.168.1.25", forKey: "podIPAddress")
        XCTAssertEqual(OwnerConnection.displayAddress, "http://192.168.1.25:3000")
        XCTAssertNil(OwnerConnection.endpoint)
        let request = OwnerConnection.authorize(URLRequest(url: URL(string: OwnerConnection.displayAddress)!), token: testKey)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        UserDefaults.standard.set(testOrigin + ":8443", forKey: "podURL")
        XCTAssertEqual(OwnerConnection.displayAddress, testOrigin + ":8443")
        UserDefaults.standard.removeObject(forKey: "podURL")
        UserDefaults.standard.removeObject(forKey: "podIPAddress")
        XCTAssertEqual(OwnerConnection.displayAddress, "")
    }
    func testHTTPSStreamMustBeExplicitAndSameHost() {
        XCTAssertNil(OwnerConnection.streamURL)
        UserDefaults.standard.set("wss://another.invalid/stream", forKey: "podStreamURL")
        XCTAssertNil(OwnerConnection.streamURL)
        UserDefaults.standard.set("wss://owner-connection.invalid/sensors", forKey: "podStreamURL")
        let stream = OwnerConnection.streamURL!
        XCTAssertEqual(OwnerConnection.streamRequest(for: stream, token: testKey).value(forHTTPHeaderField: "Authorization"), "Bearer " + testKey)
        XCTAssertNil(OwnerConnection.streamRequest(for: URL(string: "wss://another.invalid")!, token: testKey).value(forHTTPHeaderField: "Authorization"))
    }
    func testPlaintextRemoteEndpointIsRejectedBeforeSaving() {
        XCTAssertThrowsError(try UnifiedRuntime.configure(address: "http://public.invalid", token: testKey, core: true))
    }
    func testBaseReadinessRequiresReportedPositionAndFreshness() throws {
        let json = #"{"state":"connected","position":null,"stale":false,"busy":false,"lastUpdate":1}"#
        let status = try JSONDecoder().decode(UnifiedBaseStatus.self, from: Data(json.utf8))
        XCTAssertFalse(status.ready)
    }

    func testDemoReturnsToTheOwnersOriginalController() {
        APIBackend.current = .freeSleep
        APIBackend.current = .demo
        XCTAssertEqual(APIBackend.restoredLiveBackend, .freeSleep)
        APIBackend.current = .restoredLiveBackend
        XCTAssertEqual(UserDefaults.standard.string(forKey: "podNativeAPIPrefix"), "")
        APIBackend.current = .sleepypodCore
        APIBackend.current = .demo
        XCTAssertEqual(APIBackend.restoredLiveBackend, .sleepypodCore)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "podNativeAPIPrefix"), "native/v1")
    }
}
