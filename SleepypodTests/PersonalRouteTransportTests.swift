import XCTest
@testable import Sleepypod

@MainActor final class PersonalRouteTransportTests: XCTestCase {
    private func read(_ scenario: String, token: String = String(repeating: "A", count: 43)) async throws -> HouseholdSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PersonalRouteTestProtocol.self]
        let client = PersonalRouteClient(transport: URLSession(configuration: configuration))
        return try await client.read(endpoint: URL(string: "https://\(scenario).route-test.invalid")!, token: token)
    }
    func testFreshChallengeAndExplicitPersonalAuthorization() async throws {
        let value = try await read("valid")
        try value.validate()
        XCTAssertEqual(value.person.displayName, "Example member")
    }
    func testMissingOrDifferentChallengeCannotProveFreshness() async {
        for scenario in ["missing", "replayed", "html", "large"] {
            do { _ = try await read(scenario); XCTFail(scenario) }
            catch { XCTAssertTrue(error is PersonalRouteFailure || error as? HouseholdFailure == .invalid) }
        }
    }
    func testHttpErrorsAreNotNetworkFallbacks() async {
        for scenario in ["unauthorized", "forbidden", "unavailable", "redirect", "other-origin", "invalid"] {
            do { _ = try await read(scenario); XCTFail(scenario) }
            catch { XCTAssertFalse(OwnerRouteResolver.permitsFallback(after: error)) }
        }
    }
    func testTransportFailurePreservesNetworkClassification() async {
        do { _ = try await read("network"); XCTFail("Must throw") }
        catch { XCTAssertTrue(OwnerRouteResolver.permitsFallback(after: error)) }
        do { _ = try await read("tls"); XCTFail("Must throw") }
        catch { XCTAssertFalse(OwnerRouteResolver.permitsFallback(after: error)) }
    }
    func testInvalidKeyRejectedBeforeRequest() async {
        do { _ = try await read("never", token: "invalid\nkey"); XCTFail("Invalid token") }
        catch { XCTAssertEqual(error as? HouseholdFailure, .invalid) }
    }
}

private final class PersonalRouteTestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".route-test.invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let scenario = url.host?.components(separatedBy: ".").first ?? ""
        XCTAssertNotEqual(scenario, "never")
        XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
        XCTAssertEqual(url.path, "/api/v1/household/session")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + String(repeating: "A", count: 43))
        XCTAssertFalse(request.httpShouldHandleCookies); XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        let challenge = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
        XCTAssertEqual(challenge.count, 43)
        if ["network", "tls"].contains(scenario) {
            client?.urlProtocol(self, didFailWithError: URLError(scenario == "network" ? .timedOut : .serverCertificateUntrusted)); return
        }
        let status = ["unauthorized": 401, "forbidden": 403, "unavailable": 503, "redirect": 302][scenario] ?? 200
        var headers = ["Content-Type": scenario == "html" ? "text/html" : "application/json"]
        if scenario != "missing" { headers["X-Sleepypod-Connection-Challenge"] = scenario == "replayed" ? "old" : challenge }
        do {
            let fixture = try XCTUnwrap(Bundle.main.url(forResource: "household-preparation-v1", withExtension: "json"))
            let data = try Data(contentsOf: fixture)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let body: Data
            if scenario == "large" { body = Data(repeating: 65, count: 16_385) }
            else if scenario == "invalid" { body = Data("{}".utf8) }
            else { body = try JSONSerialization.data(withJSONObject: XCTUnwrap(object["memberSession"])) }
            let responseURL = scenario == "other-origin" ? URL(string: "https://different.invalid")! : url
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
