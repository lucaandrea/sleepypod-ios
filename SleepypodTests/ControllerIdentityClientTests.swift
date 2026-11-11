import XCTest
@testable import Sleepypod

@MainActor final class ControllerIdentityClientTests: XCTestCase {
    private let key = "synthetic-identity-credential-not-a-real-secret"
    private let installation = UUID(uuidString: "647f9829-7dd1-4c17-94d8-74e77732b08a")!

    private func candidate(_ behavior: String, token: String? = nil, backend: APIBackend = .sleepypodCore) throws -> OwnerConnectionCandidate {
        try .init(address: "https://\(behavior).identity.invalid", streamAddress: "", backend: backend, token: token ?? key)
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControllerIdentityProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testFreshAuthenticatedChallengeReturnsLogicalInstallationWithoutChangingConnection() async throws {
        let session = session(), original = OwnerConnection.revision
        defer { session.invalidateAndCancel() }
        let identifier = try await ControllerIdentityClient(session: session).read(candidate("valid"))
        XCTAssertEqual(identifier, installation)
        XCTAssertEqual(OwnerConnection.revision, original)
    }

    func testRejectsReplayForeignProductWrongVersionOversizedAndNonJSONReplies() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        for behavior in ["replay", "product", "version", "uuid", "url", "html", "oversized", "declared-large", "malformed"] {
            do {
                _ = try await ControllerIdentityClient(session: session).read(candidate(behavior))
                XCTFail("Invalid controller reply must fail: \(behavior)")
            } catch is ControllerIdentityFailure { }
        }
    }

    func testRejectedAccessAndRedirectDoNotBecomeUsableIdentity() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        for (behavior, status) in [("unauthorized", 401), ("forbidden", 403), ("redirect", 302), ("unavailable", 503)] {
            do {
                _ = try await ControllerIdentityClient(session: session).read(candidate(behavior))
                XCTFail("Rejected HTTP status must fail")
            } catch let APIError.invalidResponse(statusCode: actual) { XCTAssertEqual(actual, status) }
        }
    }

    func testAnonymousAndLegacyCandidatesAreRejectedBeforeSending() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        for candidate in [try candidate("must-not-send", token: ""), try candidate("must-not-send", backend: .freeSleep)] {
            do {
                _ = try await ControllerIdentityClient(session: session).read(candidate)
                XCTFail("Only authenticated Core supports identity")
            } catch is APIError { }
        }
    }
}

private final class ControllerIdentityProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".identity.invalid") == true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let behavior = url.host?.components(separatedBy: ".").first ?? ""
        XCTAssertNotEqual(behavior, "must-not-send")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-identity-credential-not-a-real-secret")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(url.path, "/api/v1/connection")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.count, 1); XCTAssertEqual(query.first?.name, "challenge")
        let challenge = query.first?.value ?? ""
        XCTAssertEqual(challenge.count, 43)
        XCTAssertNotNil(challenge.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression))
        let status = ["unauthorized": 401, "forbidden": 403, "redirect": 302, "unavailable": 503][behavior] ?? 200
        var payload: [String: Any] = ["schemaVersion": 1, "controller": "sleepypod-core",
            "installationId": "647f9829-7dd1-4c17-94d8-74e77732b08a", "challenge": challenge]
        if behavior == "replay" { payload["challenge"] = String(repeating: "x", count: 43) }
        if behavior == "product" { payload["controller"] = "other-product" }
        if behavior == "version" { payload["schemaVersion"] = 2 }
        if behavior == "uuid" { payload["installationId"] = "not-an-identifier" }
        if behavior == "oversized" { payload["extra"] = String(repeating: "x", count: 8193) }
        let body = behavior == "malformed" ? Data("not JSON".utf8) : (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let responseURL = behavior == "url" ? URL(string: "https://different.identity.invalid/api/v1/connection")! : url
        var headers = ["Content-Type": behavior == "html" ? "text/html" : "application/json"]
        if behavior == "declared-large" { headers["Content-Length"] = "9000" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
