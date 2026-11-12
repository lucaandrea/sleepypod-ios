import XCTest
@testable import Sleepypod

@MainActor final class PersonalLearningTransportTests: XCTestCase {
    private func client(_ account: HouseholdSession? = nil) throws -> PersonalLearningHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PersonalLearningProtocol.self]
        return .init(connection: PersonalHistoryFixtures.connection(try account ?? PersonalLearningFixtures.session()), transport: URLSession(configuration: configuration))
    }
    func testOnlyBoundedPersonalGetRoutesWithPinnedIdentityAreSent() async throws {
        let client = try client(), archives = try PersonalLearningFixtures.data("archives"), records = try PersonalLearningFixtures.data("records")
        let detail = try PersonalLearningFixtures.data("detail"), session = try PersonalLearningFixtures.data("session")
        let archive = try XCTUnwrap(PersonalLearningFixtures.archives().archives.first?.id), record = try PersonalLearningFixtures.detail().recordId
        PersonalLearningProtocol.set { request in
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(client.connection.token)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Sleepypod-Sleeper-Id"), client.connection.session.selfSleeperId)
            XCTAssertFalse(request.httpShouldHandleCookies)
            switch request.url?.path {
            case "/api/v1/household/session": return .init(body: session)
            case "/api/v1/me/learning/archives":
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, [.init(name: "limit", value: "20")])
                return .init(body: archives)
            case "/api/v1/me/learning/records":
                let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
                XCTAssertEqual(fields, ["archiveId": archive, "after": "0", "limit": "20"])
                return .init(body: records)
            case "/api/v1/me/learning/records/\(record)": XCTAssertNil(request.url?.query); return .init(body: detail)
            default: XCTFail("Unexpected route"); return .init(status: 404)
            }
        }
        _ = try await client.session(); _ = try await client.archives(before: nil); _ = try await client.records(archiveId: archive, after: 0)
        _ = try await client.detail(recordId: record)
        XCTAssertEqual(PersonalLearningProtocol.count, 4)
    }
    func testInvalidSelectorsAndDisabledCapabilitiesNeverReachNetwork() async throws {
        PersonalLearningProtocol.set { _ in XCTFail("Unexpected request"); return .init() }
        let client = try client()
        for before in ["", "../owner", "record?side=left"] {
            do { _ = try await client.archives(before: before); XCTFail("Invalid selector") } catch {}
            do { _ = try await client.detail(recordId: before); XCTFail("Invalid selector") } catch {}
        }
        do { _ = try await client.archives(before: nil, limit: 51); XCTFail("Invalid limit") } catch {}
        do { _ = try await client.records(archiveId: UUID().uuidString, after: -1); XCTFail("Invalid cursor") } catch {}
        let disabled: HouseholdSession = try PersonalHistoryFixtures.changed(PersonalLearningFixtures.session()) {
            var capabilities = $0["capabilities"] as! [String: Any]; capabilities["personalLearningArchive"] = false; $0["capabilities"] = capabilities
        }
        do { _ = try await self.client(disabled).archives(before: nil); XCTFail("Disabled") } catch {}
        XCTAssertEqual(PersonalLearningProtocol.count, 0)
    }
    func testErrorsDoNotRetryOrExposeResponseBodies() async throws {
        let client = try client()
        for (status, expected): (Int, HouseholdFailure) in [(401, .authentication), (403, .forbidden), (404, .unavailable), (409, .conflict), (429, .rateLimited), (503, .unavailable), (302, .invalid)] {
            PersonalLearningProtocol.set { _ in .init(status: status, body: Data("private server text".utf8)) }
            do { _ = try await client.archives(before: nil); XCTFail("Must reject error") }
            catch { XCTAssertEqual(error as? HouseholdFailure, expected); XCTAssertFalse(error.localizedDescription.contains("private server")) }
            XCTAssertEqual(PersonalLearningProtocol.count, 1)
        }
    }
    func testOversizedTruncatedAndNonJsonStreamsAreRejected() async throws {
        let client = try client()
        for reply in [
            PersonalLearningProtocol.Reply(body: Data(repeating: 32, count: 524_289)),
            .init(body: Data("{".utf8)),
            .init(body: try PersonalLearningFixtures.data("archives"), type: "text/plain"),
            .init(body: Data("{}".utf8), length: "999999999"),
            .init(body: Data("{}".utf8), failure: true)
        ] {
            PersonalLearningProtocol.set { _ in reply }
            do { _ = try await client.archives(before: nil); XCTFail("Invalid stream") } catch {}
            XCTAssertEqual(PersonalLearningProtocol.count, 1)
        }
    }
    func testRemovalPostsOnlyReviewedBodyAndReceiptRecoveryUsesGet() async throws {
        let client = try client(LearningRemovalFixtures.session()), removal = try LearningRemovalFixtures.request()
        let response = try JSONEncoder().encode(LearningRemovalFixtures.response(removal))
        PersonalLearningProtocol.set { request in
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(client.connection.token)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Sleepypod-Sleeper-Id"), client.connection.session.selfSleeperId)
            if request.url?.path == "/api/v1/me/learning/records/\(removal.recordId)/remove" {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                var body = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 2_048)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        guard count > 0 else { break }; body.append(contentsOf: buffer.prefix(count))
                    }
                }
                XCTAssertEqual(try? JSONDecoder().decode(PersonalLearningRemovalRequest.self, from: body), removal)
            } else {
                XCTAssertEqual(request.url?.path, "/api/v1/me/learning/requests/\(removal.requestId)")
                XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
            }
            return .init(body: response)
        }
        _ = try await client.remove(removal); _ = try await client.removalReceipt(requestId: removal.requestId)
        XCTAssertEqual(PersonalLearningProtocol.count, 2)
    }
    func testRemovalRequiresCapabilityAndValidReviewBeforeSending() async throws {
        PersonalLearningProtocol.set { _ in XCTFail("Unexpected removal"); return .init() }
        let request = try LearningRemovalFixtures.request()
        do { _ = try await client().remove(request); XCTFail("Missing capability") } catch {}
        let client = try client(LearningRemovalFixtures.session())
        for field in ["recordId", "archiveId", "expectedPayloadHash", "confirmRemoveArchivedCopy", "expectedSessionRevision"] {
            let changed: PersonalLearningRemovalRequest = try PersonalHistoryFixtures.changed(request) {
                if field == "confirmRemoveArchivedCopy" { $0[field] = false }
                else if field == "expectedSessionRevision" { $0[field] = 999 }
                else { $0[field] = "../owner" }
            }
            do { _ = try await client.remove(changed); XCTFail("Invalid review") } catch {}
        }
        do { _ = try await client.removalReceipt(requestId: "../owner"); XCTFail("Invalid request ID") } catch {}
        XCTAssertEqual(PersonalLearningProtocol.count, 0)
    }
}

private final class PersonalLearningProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var body = Data()
        var type = "application/json"
        var length: String?
        var failure = false
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: (@Sendable (URLRequest) -> Reply)?
        var count = 0
    }
    private static let state = State()
    static var count: Int { state.lock.withLock { state.count } }
    static func set(_ handler: @escaping @Sendable (URLRequest) -> Reply) { state.lock.withLock { state.handler = handler; state.count = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "history-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.state.lock.withLock { Self.state.count += 1; return Self.state.handler }
        guard let address = request.url, let reply = handler?(request) else { return }
        var headers = ["Content-Type": reply.type]
        if let length = reply.length { headers["Content-Length"] = length }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: address, statusCode: reply.status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        if reply.failure { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
        else { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}
