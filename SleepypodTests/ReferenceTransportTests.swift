import XCTest
@testable import Sleepypod

@MainActor final class ReferenceTransportTests: XCTestCase {
    func testCorePreviewAndPairedLibraryAndMeasurementCursors() async throws {
        let fixture = ReferenceHTTPFixture(); defer { fixture.close() }
        let sample = try ReferenceDemoFixture.load(side: .right)
        fixture.state.responses = [try JSONEncoder().encode(sample.summary), Data(#"{"items":[],"nextCursor":null}"#.utf8), try JSONEncoder().encode(ReferenceMeasurementPage(items: sample.measurements, nextCursor: 4))]
        let preview = try await fixture.client.preview(sample.input)
        XCTAssertEqual(preview, sample.summary)
        let identifier = "10000000-0000-4000-8000-000000000001"
        _ = try await fixture.client.library(side: .right, cursor: .init(createdAtMs: 1792920000123, id: identifier))
        let records = try await fixture.client.measurements(id: identifier, after: 102)
        XCTAssertEqual(records.nextCursor, 4); XCTAssertEqual(records.items.count, 4)
        let requests = fixture.state.requests
        XCTAssertEqual(requests.map(\.method), ["POST", "GET", "GET"])
        XCTAssertEqual(requests.map(\.path), ["/api/biometric-tuning/references/preview", "/api/biometric-tuning/references", "/api/biometric-tuning/references/\(identifier)/measurements"])
        XCTAssertEqual(Set(requests[0].body.keys), ["side", "subjectId", "source", "rows"])
        XCTAssertEqual(requests[1].query, ["side": "right", "beforeCreatedAtMs": "1792920000123", "beforeId": identifier])
        XCTAssertEqual(requests[2].query, ["afterId": "102", "limit": "100"])
    }
    func testExactCommitEnvelopeAndDeleteReceiptWithoutAutomaticRetry() async throws {
        let fixture = ReferenceHTTPFixture(); defer { fixture.close() }
        let sample = try ReferenceDemoFixture.load(side: .left)
        let request = ReferenceCommit(input: sample.input, previewHash: sample.summary.contentHash, acceptRejectedRows: true, supersedesImportId: nil)
        fixture.state.failWrites = true
        do { _ = try await fixture.client.commit(request); XCTFail("Expected unknown result") } catch {}
        XCTAssertEqual(fixture.state.requests.count, 1)
        let posted = fixture.state.requests[0]
        XCTAssertEqual(posted.path, "/api/biometric-tuning/references/commit")
        XCTAssertEqual(Set(posted.body.keys), ["import", "previewHash", "acceptRejectedRows"])
        XCTAssertEqual(posted.body["previewHash"] as? String, sample.summary.contentHash)
        XCTAssertEqual(posted.body["acceptRejectedRows"] as? Bool, true)
        XCTAssertEqual((posted.body["import"] as? [String: Any])?["side"] as? String, "left")
        fixture.state.failWrites = false
        let identifier = "10000000-0000-4000-8000-000000000001"
        fixture.state.responses = [Data("{\"id\":\"\(identifier)\",\"deletedAtMs\":1792920000123}".utf8)]
        let receipt = try await fixture.client.delete(id: identifier)
        XCTAssertEqual(receipt.id, identifier); XCTAssertEqual(receipt.deletedAtMs, 1792920000123)
        XCTAssertEqual(fixture.state.requests.last?.method, "DELETE")
        XCTAssertEqual(fixture.state.requests.last?.path, "/api/biometric-tuning/references/\(identifier)")
    }
    func testInvalidRouteIdentitiesAndCursorsNeverSend() async throws {
        let fixture = ReferenceHTTPFixture(); defer { fixture.close() }
        do { _ = try await fixture.client.descriptor(id: "../other"); XCTFail("Invalid ID") } catch {}
        do { _ = try await fixture.client.delete(id: "broken?x=y"); XCTFail("Invalid ID") } catch {}
        do { _ = try await fixture.client.library(side: .left, cursor: .init(createdAtMs: .nan, id: UUID().uuidString)); XCTFail("Invalid cursor") } catch {}
        do { _ = try await fixture.client.measurements(id: UUID().uuidString, after: -1); XCTFail("Invalid cursor") } catch {}
        XCTAssertTrue(fixture.state.requests.isEmpty)
    }
}

private final class ReferenceHTTPFixture {
    let host = "references-\(UUID().uuidString.lowercased()).invalid"
    let state = ReferenceHTTPState()
    let session: URLSession
    var client: CoreBiometricReferencesClient { .init(transport: .init(endpoint: URL(string: "https://\(host)")!, session: session)) }
    init() {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ReferenceHTTPProtocol.self]
        session = URLSession(configuration: config); ReferenceHTTPProtocol.registry.register(state, host: host)
    }
    func close() { session.invalidateAndCancel(); ReferenceHTTPProtocol.registry.remove(host) }
}
private final class ReferenceHTTPState: @unchecked Sendable {
    struct Request { let method: String; let path: String; let query: [String: String]; let body: [String: Any] }
    private let lock = NSLock()
    private var values: [Data] = []
    private var writesFail = false
    private var received: [Request] = []
    var responses: [Data] { get { lock.withLock { values } } set { lock.withLock { values = newValue } } }
    var failWrites: Bool { get { lock.withLock { writesFail } } set { lock.withLock { writesFail = newValue } } }
    var requests: [Request] { lock.withLock { received } }
    func reply(_ request: URLRequest) throws -> Data {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        }
        let body = data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return try lock.withLock {
            received.append(.init(method: request.httpMethod ?? "", path: request.url!.path, query: Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }), body: body))
            if writesFail && request.httpMethod != "GET" { throw URLError(.timedOut) }
            guard !values.isEmpty else { throw URLError(.badServerResponse) }; return values.removeFirst()
        }
    }
}
private final class ReferenceHTTPRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ReferenceHTTPState] = [:]
    func register(_ state: ReferenceHTTPState, host: String) { lock.withLock { values[host] = state } }
    func remove(_ host: String) { _ = lock.withLock { values.removeValue(forKey: host) } }
    func state(_ host: String) -> ReferenceHTTPState? { lock.withLock { values[host] } }
}
private final class ReferenceHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let registry = ReferenceHTTPRegistry()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host.flatMap(registry.state) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let state = Self.registry.state(url.host ?? "") else { return }
        do {
            let data = try state.reply(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
