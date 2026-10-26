import XCTest
@testable import Sleepypod

@MainActor final class ImportedHistoryRESTTests: XCTestCase {
    func testReadOnlyRoutesAndOpaqueCursorRemainExact() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [HistoryRequestProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let client = CoreImportedHistoryClient(transport: .init(endpoint: URL(string: "https://history-contract.invalid")!, session: session))
        let status = try await client.status(); try status.validate(); let snapshot = try XCTUnwrap(status.snapshot)
        var query = ImportedHistoryQuery(snapshotID: snapshot.snapshotId, side: .left, kind: .presence,
                                         start: Date(timeIntervalSince1970: 1_792_368_000), end: Date(timeIntervalSince1970: 1_792_972_800))
        query.cursor = "one&two+three"; query.limit = 42
        let page = try await client.page(query); XCTAssertEqual(page.records.count, 1)
        let detail = try await client.presence(snapshotID: snapshot.snapshotId, record: ImportedHistoryExample.load().detail.record)
        XCTAssertEqual(detail.snapshotId, snapshot.snapshotId)
    }
    func testSnapshotConflictAndRejectedKeyAreDistinct() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [HistoryRequestProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let changed = CoreImportedHistoryClient(transport: .init(endpoint: URL(string: "https://changed.invalid")!, session: session))
        do { _ = try await changed.status(); XCTFail("Expected a snapshot conflict") }
        catch ImportedHistoryFailure.changed { } catch { XCTFail("Wrong failure: \(error)") }
        let rejected = CoreImportedHistoryClient(transport: .init(endpoint: URL(string: "https://rejected.invalid")!, session: session))
        do { _ = try await rejected.status(); XCTFail("Expected rejected connection key") }
        catch { XCTAssertEqual(error.localizedDescription, "The controller rejected the connection key.") }
    }
}

private final class HistoryRequestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = request.url!, fixtureURL = Bundle.main.url(forResource: "imported-history-example", withExtension: "json")!
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any]
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            var valid = request.httpMethod == "GET" && request.httpBody == nil && request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData
            let body: Any
            switch url.path {
            case "/api/v1/history": valid = valid && query.isEmpty; body = fixture["status"]!
            case "/api/v1/history/records":
                let snapshot = (fixture["status"] as! [String: Any])["snapshot"] as! [String: Any]
                valid = valid && Set(query.keys) == ["snapshotId", "side", "kind", "startTime", "endTime", "cursor", "limit"]
                    && query["side"] == "left" && query["kind"] == "presence" && query["snapshotId"] == snapshot["snapshotId"] as? String
                    && query["cursor"] == "one&two+three" && query["limit"] == "42"
                    && ISO8601DateFormatter().date(from: query["startTime"] ?? "")?.timeIntervalSince1970 == 1_792_368_000
                    && ISO8601DateFormatter().date(from: query["endTime"] ?? "")?.timeIntervalSince1970 == 1_792_972_800
                body = (fixture["pages"] as! [String: Any])["presence"]!
            case "/api/v1/history/presence":
                let snapshot = (fixture["status"] as! [String: Any])["snapshot"] as! [String: Any]
                valid = valid && query == ["snapshotId": snapshot["snapshotId"] as! String, "side": "left", "id": "2"]
                body = fixture["detail"]!
            default: valid = false; body = ["message": "Unexpected route"]
            }
            let status = url.host == "changed.invalid" ? 409 : url.host == "rejected.invalid" ? 401 : valid ? 200 : 422
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Cache-Control": "private, no-store"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
