import XCTest
@testable import Sleepypod

@MainActor final class PersonalQuietTransportTests: XCTestCase {
    private func client(enabled: Bool = true) throws -> PersonalQuietHTTPClient {
        let session = try PersonalHistoryFixtures.changed(PersonalQuietFixtures.session()) {
            var capabilities = $0["capabilities"] as! [String: Any]
            capabilities["householdQuiet"] = enabled; $0["capabilities"] = capabilities
        }
        let connection = PersonalBedConnection(id: UUID(), endpoint: URL(string: "https://quiet-fixture.invalid")!,
            token: String(repeating: "A", count: 43), session: session)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PersonalQuietProtocol.self]
        return .init(connection: connection, transport: URLSession(configuration: configuration, delegate: PersonalHistoryRedirectPolicy(), delegateQueue: nil))
    }
    func testPersonalGetAndWriteRoutesUsePinnedIdentityAndExplicitClear() async throws {
        let client = try client(), page = try PersonalQuietFixtures.data("idle"), result = try PersonalQuietFixtures.data("missing")
        let session = try JSONEncoder().encode(client.connection.session), sleeper = client.connection.session.selfSleeperId
        PersonalQuietProtocol.set { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(String(repeating: "A", count: 43))")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Sleepypod-Sleeper-Id"), sleeper)
            XCTAssertFalse(request.httpShouldHandleCookies); XCTAssertNil(request.url?.query)
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.path, "/api/v1/me/quiet")
                let body = try! JSONSerialization.jsonObject(with: PersonalQuietProtocol.body(request)) as! [String: Any]
                XCTAssertTrue(body["until"] is NSNull); XCTAssertTrue(body["expectedRevision"] is NSNull)
                XCTAssertNil(body["accountId"]); XCTAssertNil(body["side"])
                return (200, result, "application/json", nil)
            }
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, request.url?.path == "/api/v1/household/session" ? session : request.url?.path == "/api/v1/me/quiet" ? page : result,
                    "application/json", nil)
        }
        _ = try await client.session(); _ = try await client.read(); _ = try await client.receipt(requestId: UUID().uuidString)
        _ = try await client.write(.init(requestId: UUID().uuidString, expectedSessionRevision: 1, expectedAssignmentRevision: 1,
            expectedRevision: nil, issuedAt: 1000, expiresAt: 31_000, until: nil))
        XCTAssertEqual(PersonalQuietProtocol.count, 4)
    }
    func testMissingCapabilityInvalidReceiptAndInvalidWriteCannotSend() async throws {
        PersonalQuietProtocol.set { _ in XCTFail("No request allowed"); return (200, Data(), "application/json", nil) }
        do { _ = try await client(enabled: false).read(); XCTFail("Disabled") } catch {}
        let enabled = try client()
        do { _ = try await enabled.receipt(requestId: "../another-person"); XCTFail("Invalid path") } catch {}
        do {
            _ = try await enabled.write(.init(requestId: UUID().uuidString, expectedSessionRevision: 1, expectedAssignmentRevision: 1,
                expectedRevision: nil, issuedAt: 1000, expiresAt: 61_001, until: nil)); XCTFail("Expired too late")
        } catch {}
        XCTAssertEqual(PersonalQuietProtocol.count, 0)
    }
    func testErrorsAndDroppedRepliesAreNotRetriedOrExposed() async throws {
        let client = try client()
        for (status, expected): (Int, HouseholdFailure) in [(401, .authentication), (403, .forbidden), (409, .conflict),
                                                          (404, .unavailable), (503, .unavailable), (429, .rateLimited), (302, .invalid), (-1, .uncertain)] {
            PersonalQuietProtocol.set { _ in (status, Data("private-response".utf8), "application/json", nil) }
            do { _ = try await client.read(); XCTFail("Must fail") }
            catch { XCTAssertEqual(error as? HouseholdFailure, expected); XCTAssertFalse(error.localizedDescription.contains("private-response")) }
            XCTAssertEqual(PersonalQuietProtocol.count, 1)
        }
    }
    func testRejectsOversizedNonJSONTruncatedAndWrongOriginResponses() async throws {
        let client = try client(), valid = try PersonalQuietFixtures.data("idle")
        for (body, mime, address) in [(Data(repeating: 32, count: 16_385), "application/json", nil as URL?),
                                      (valid, "text/html", nil), (Data("{".utf8), "application/json", nil),
                                      (valid, "application/json", URL(string: "https://other.invalid/api/v1/me/quiet"))] {
            PersonalQuietProtocol.set { _ in (200, body, mime, address) }
            do { _ = try await client.read(); XCTFail("Must reject response") } catch {}
            XCTAssertEqual(PersonalQuietProtocol.count, 1)
        }
    }
}

private final class PersonalQuietProtocol: URLProtocol, @unchecked Sendable {
    typealias Response = (Int, Data, String, URL?)
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: (@Sendable (URLRequest) -> Response)?
        var count = 0
    }
    private static let state = State()
    static var count: Int { state.lock.withLock { state.count } }
    static func set(_ handler: @escaping @Sendable (URLRequest) -> Response) { state.lock.withLock { state.handler = handler; state.count = 0 } }
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        return data
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "quiet-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.state.lock.withLock { Self.state.count += 1; return Self.state.handler }
        guard let url = request.url, let (status, data, mime, address) = handler?(request) else { return }
        if status == -1 { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: address ?? url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": mime])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
