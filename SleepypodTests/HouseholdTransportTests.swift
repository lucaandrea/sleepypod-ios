import XCTest
@testable import FreeSleepKit
@testable import Sleepypod

@MainActor final class HouseholdTransportTests: XCTestCase {
    func testPersonalTransportUsesOnlyExplicitTokenAndVersionedAllowlist() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [HouseholdContractProtocol.self]
        let client = HouseholdHTTPClient(endpoint: URL(string: "https://personal-contract.invalid")!, session: URLSession(configuration: configuration))
        _ = try await client.send(path: "household/session", method: "GET", token: "personal-test-token", body: nil)
        _ = try await client.send(path: "household/join", method: "POST", token: nil, body: Data("{}".utf8))
        for path in ["settings", "../controls", "health/import", "me/preferences?token=x", "me/history"] {
            do { _ = try await client.send(path: path, method: "GET", token: "personal-test-token", body: nil); XCTFail("Unsupported path must fail before networking") }
            catch { XCTAssertEqual(error as? HouseholdFailure, .invalid) }
        }
        do { _ = try await client.send(path: "me/preferences", method: "DELETE", token: "x", body: nil); XCTFail("Unsupported method") } catch {}
    }
    func testPersonalBoundaryRejectsEveryLegacyTransportBeforeNetwork() async throws {
        try await PersonalWorkspaceBoundary.$suppliedActive.withValue(true) {
            let endpoint = URL(string: "https://never-connect.invalid")!
            XCTAssertThrowsError(try CoreRESTClient(endpoint: endpoint).request("settings", method: "GET"))
            do { _ = try await SleepypodCoreClient(baseURL: endpoint).getSettings(); XCTFail("tRPC must be gated") } catch {}
            do { _ = try await FreeSleepClient(baseURL: endpoint).getSettings(); XCTFail("REST must be gated") } catch {}
            XCTAssertThrowsError(try AppMode.requireLiveConnection())
        }
    }
    func testOwnerPreparationCapabilityRequiresExplicitReadyFeature() throws {
        for json in [#"{"apiVersion":1}"#, #"{"apiVersion":1,"features":{}}"#, #"{"apiVersion":1,"features":{"householdPreparation":{"implemented":true,"runtime":"unavailable"}}}"#] {
            XCTAssertFalse(try JSONDecoder().decode(HouseholdPreparationCapability.self, from: Data(json.utf8)).ready)
        }
        XCTAssertTrue(try JSONDecoder().decode(HouseholdPreparationCapability.self, from: Data(#"{"apiVersion":1,"features":{"householdPreparation":{"implemented":true,"runtime":"ready"}}}"#.utf8)).ready)
    }
}

private final class HouseholdContractProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "personal-contract.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie")); XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(url.query)
        if url.path == "/api/v1/household/session" {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer personal-test-token")
        } else {
            XCTAssertEqual(url.path, "/api/v1/household/join"); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
