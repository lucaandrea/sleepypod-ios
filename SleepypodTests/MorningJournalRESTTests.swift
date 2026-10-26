import XCTest
@testable import Sleepypod

@MainActor final class MorningJournalRESTTests: XCTestCase {
    private func client(_ host: String) -> (CoreMorningJournalClient, URLSession) {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [JournalRequestProtocol.self]
        let session = URLSession(configuration: config)
        return (.init(transport: .init(endpoint: URL(string: "https://\(host)")!, session: session)), session)
    }
    func testCapabilitiesExactReadAndRevisionCheckedSaveAndDelete() async throws {
        let (client, session) = client("journal-contract.invalid"); defer { session.invalidateAndCancel() }
        try await client.available()
        let page = try await client.read(side: .left, date: "2026-10-25", days: 30); try page.validate(side: .left, date: "2026-10-25", days: 30)
        let saved = try await client.write(.init(side: .left, date: page.through, expectedRevision: page.selected.revision, fields: page.selected.record?.fields))
        XCTAssertNotEqual(saved.revision, page.selected.revision)
        let deleted = try await client.write(.init(side: .left, date: page.through, expectedRevision: saved.revision, fields: nil))
        XCTAssertNil(deleted.record); XCTAssertNotNil(deleted.revision)
    }
    func testConflictAndRejectedKeyDoNotForwardPrivateErrorBodies() async throws {
        let (conflict, first) = client("journal-conflict.invalid"); defer { first.invalidateAndCancel() }
        do { _ = try await conflict.read(side: .left, date: nil, days: 30); XCTFail("Expected conflict") }
        catch MorningJournalFailure.conflict {} catch { XCTFail("Wrong error") }
        let (rejected, second) = client("journal-rejected.invalid"); defer { second.invalidateAndCancel() }
        do { try await rejected.available(); XCTFail("Expected key failure") }
        catch { XCTAssertEqual(error.localizedDescription, "The controller rejected the connection key."); XCTAssertFalse(error.localizedDescription.contains("PRIVATE")) }
        let (failed, third) = client("journal-failed.invalid"); defer { third.invalidateAndCancel() }
        do { _ = try await failed.read(side: .left, date: nil, days: 30); XCTFail("Expected error") }
        catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE")) }
    }
    func testUnsupportedCapabilityCannotRedirectJournalRequests() async throws {
        let (client, session) = client("journal-unsupported.invalid"); defer { session.invalidateAndCancel() }
        do { try await client.available(); XCTFail("External advertised endpoint must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("does not yet support")) }
    }
}

private final class JournalRequestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = request.url!, source = try MorningJournalExample.load().page
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            var valid = request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData
            var status = 200
            let data: Data
            if url.host == "journal-conflict.invalid" { status = 409; data = Data("{\"message\":\"PRIVATE note\"}".utf8) }
            else if url.host == "journal-rejected.invalid" || url.host == "journal-failed.invalid" {
                status = url.host == "journal-rejected.invalid" ? 401 : 500; data = Data("{\"message\":\"PRIVATE note\"}".utf8)
            } else if url.path == "/api/v1/capabilities" {
                valid = valid && request.httpMethod == "GET" && query.isEmpty
                data = try JSONSerialization.data(withJSONObject: ["apiVersion": 1, "features": ["morningJournal": ["implemented": true, "runtime": "ready"]],
                    "endpoints": ["journal": url.host == "journal-unsupported.invalid" ? "https://another.invalid/journal" : "/api/v1/journal"]])
            } else if url.path == "/api/v1/journal", request.httpMethod == "GET" {
                valid = valid && query == ["side": "left", "date": "2026-10-25", "days": "30"]; data = try JSONEncoder().encode(source)
            } else if url.path == "/api/v1/journal", request.httpMethod == "POST" {
                let payload = try JSONSerialization.jsonObject(with: body()) as! [String: Any]
                valid = valid && query.isEmpty && Set(payload.keys) == ["side", "date", "expectedRevision", "fields"]
                    && payload["side"] as? String == "left" && payload["date"] as? String == source.through
                let deleting = payload["fields"] is NSNull
                let revision = deleting ? "20000000-0000-4000-8000-000000000002" : "20000000-0000-4000-8000-000000000001"
                valid = valid && payload["expectedRevision"] as? String == (deleting ? "20000000-0000-4000-8000-000000000001" : source.selected.revision)
                if !deleting {
                    let fields = try JSONDecoder().decode(MorningJournalFields.self, from: JSONSerialization.data(withJSONObject: payload["fields"]!))
                    valid = valid && fields == source.selected.record?.fields
                }
                data = try JSONEncoder().encode(MorningJournalSelection(side: .left, date: source.through, revision: revision, record: deleting ? nil : source.selected.record))
            } else { valid = false; data = Data("{}".utf8) }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: valid ? status : 422, httpVersion: nil, headerFields: ["Cache-Control": "private, no-store"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func body() throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { throw MorningJournalFailure.invalid }
        stream.open(); defer { stream.close() }; var data = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); guard count >= 0 else { throw MorningJournalFailure.invalid }; if count == 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
        return data
    }
    override func stopLoading() {}
}
