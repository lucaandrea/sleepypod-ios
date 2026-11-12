import Foundation
import XCTest
@testable import FreeSleepKit

@MainActor final class MorningReportTransportTests: XCTestCase {
    private let reportID = UUID(uuidString: "120c83db-50f9-4fef-879d-5dc603978bea")!
    private let installationID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let revision = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let now = Date(timeIntervalSince1970: 1_793_635_600)
    private var owner: MorningReportScope { .owner(installationID: installationID) }

    private func client(scope: MorningReportScope? = nil, endpoint: String = "https://report-fixture.invalid", token: String = "fixture-token") throws -> MorningReportHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MorningReportProtocol.self]
        let now = now
        return try .init(endpoint: XCTUnwrap(URL(string: endpoint)), token: token, scope: scope ?? owner,
                         transport: URLSession(configuration: configuration), now: { now })
    }
    private func document() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "morning-report-v1", withExtension: "json"))
        return try Data(contentsOf: url)
    }
    private func envelope(deleted: Bool = false, scope: [String: Any]? = nil, change: (inout [String: Any]) throws -> Void = { _ in }) throws -> Data {
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: document()) as? [String: Any])
        var object: [String: Any] = ["version": 1, "generatedAt": 1_793_635_600_000,
            "scope": scope ?? ["kind": "legacy", "installationId": installationID.uuidString.lowercased()],
            "receipt": ["id": reportID.uuidString.lowercased(), "revision": revision.uuidString.lowercased(), "deleted": deleted,
                        "createdAt": 1_793_635_500_000, "receivedAt": 1_793_635_570_000, "updatedAt": 1_793_635_580_000],
            "report": deleted ? NSNull() : document["report"]!]
        try change(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testOwnerReadShareAndWithdrawalUseOnlyExplicitPinnedRoute() async throws {
        let transport = try client(), response = try envelope(), deleted = try envelope(deleted: true)
        MorningReportProtocol.set { request in .init(body: request.httpMethod == "DELETE" ? deleted : response) }
        let read = try await transport.read(id: reportID)
        XCTAssertEqual(read?.receipt.id, reportID); XCTAssertNotNil(read?.document)
        let shared = try await transport.share(id: reportID, document: document(), expectedRevision: nil)
        XCTAssertFalse(shared.receipt.deleted)
        let removed = try await transport.withdraw(id: reportID, expectedRevision: revision)
        XCTAssertTrue(removed.receipt.deleted); XCTAssertNil(removed.document)
        let requests = MorningReportProtocol.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PUT", "DELETE"])
        for request in requests {
            XCTAssertEqual(request.url?.absoluteString, "https://report-fixture.invalid/api/v1/reports/\(reportID.uuidString.lowercased())")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Sleepypod-Sleeper-Id"))
            XCTAssertFalse(request.httpShouldHandleCookies)
        }
        let upload = try MorningReportProtocol.body(requests[1]), withdrawal = try MorningReportProtocol.body(requests[2])
        XCTAssertEqual(Set(upload.keys), ["document", "expectedRevision"])
        XCTAssertTrue(upload["expectedRevision"] is NSNull)
        XCTAssertEqual(withdrawal["expectedRevision"] as? String, revision.uuidString.lowercased())
        XCTAssertEqual(Set(withdrawal.keys), ["expectedRevision"])
    }

    func testPersonalReportUsesOwnAccountAndRejectsAChangedSessionOrHousehold() async throws {
        let pod = UUID(), household = UUID(), account = UUID(), sleeper = UUID()
        let personal = MorningReportScope.personal(podID: pod, householdID: household, accountID: account, sleeperID: sleeper,
                                                   sessionRevision: 2, householdRevision: 3, assignmentRevision: 4)
        let scope: [String: Any] = ["podId": pod.uuidString, "householdId": household.uuidString, "accountId": account.uuidString,
            "sleeperId": sleeper.uuidString, "sessionRevision": 2, "householdRevision": 3, "assignmentRevision": 4]
        let transport = try client(scope: personal), response = try envelope(scope: scope)
        MorningReportProtocol.set { _ in .init(body: response) }
        _ = try await transport.read(id: reportID)
        let request = try XCTUnwrap(MorningReportProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/me/reports/\(reportID.uuidString.lowercased())")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Sleepypod-Sleeper-Id"), sleeper.uuidString.lowercased())
        for field in ["accountId", "sleeperId", "sessionRevision", "householdRevision", "assignmentRevision"] {
            var changed = scope; changed[field] = field.hasSuffix("Revision") ? 10 : UUID().uuidString
            let invalid = try envelope(scope: changed)
            MorningReportProtocol.set { _ in .init(body: invalid) }
            do { _ = try await transport.read(id: reportID); XCTFail("Changed identity accepted: \(field)") }
            catch { XCTAssertEqual(error as? MorningReportSharingFailure, .invalid) }
            XCTAssertEqual(MorningReportProtocol.requests.count, 1)
        }
    }

    func testOnlyAnExplicitMissingReportCanBeShownAsNotShared() async throws {
        let transport = try client()
        MorningReportProtocol.set { _ in .init(status: 404, body: Data(#"{"error":{"code":"not_found"}}"#.utf8)) }
        let missing = try await transport.read(id: reportID); XCTAssertNil(missing)
        for payload in [Data(#"{"error":{"code":"unavailable"}}"#.utf8), Data("Unknown route".utf8)] {
            MorningReportProtocol.set { _ in .init(status: 404, body: payload) }
            do { _ = try await transport.read(id: reportID); XCTFail("Unavailable controller appeared unshared") }
            catch { XCTAssertEqual(error as? MorningReportSharingFailure, .unavailable) }
        }
    }

    func testResponseValidationRejectsWrongReceiptIdentityClocksAndDeletedPayloads() async throws {
        let transport = try client()
        let changes: [(inout [String: Any]) throws -> Void] = [
            { $0["version"] = true }, { $0["generatedAt"] = true }, { $0["generatedAt"] = 1_793_635_700_001 },
            { $0["scope"] = ["kind": "legacy", "installationId": UUID().uuidString] },
            { var receipt = try XCTUnwrap($0["receipt"] as? [String: Any]); receipt["id"] = UUID().uuidString; $0["receipt"] = receipt },
            { var receipt = try XCTUnwrap($0["receipt"] as? [String: Any]); receipt["updatedAt"] = 1_793_635_500_000; $0["receipt"] = receipt },
            { var receipt = try XCTUnwrap($0["receipt"] as? [String: Any]); receipt["receivedAt"] = 1.5; $0["receipt"] = receipt },
            { var receipt = try XCTUnwrap($0["receipt"] as? [String: Any]); receipt["deleted"] = true; $0["receipt"] = receipt },
            { var report = try XCTUnwrap($0["report"] as? [String: Any]); report["id"] = UUID().uuidString; $0["report"] = report },
            { var report = try XCTUnwrap($0["report"] as? [String: Any]); report["createdAt"] = 1_793_635_400_000; $0["report"] = report },
            { $0["report"] = NSNull() }
        ]
        for change in changes {
            let response = try envelope(change: change)
            MorningReportProtocol.set { _ in .init(body: response) }
            do { _ = try await transport.read(id: reportID); XCTFail("Unverified response accepted") }
            catch { XCTAssertEqual(error as? MorningReportSharingFailure, .invalid) }
        }
    }

    func testAnUnseenWithdrawalHasNoCreationDateOrReport() throws {
        let response = try envelope(deleted: true) { object in
            var receipt = try XCTUnwrap(object["receipt"] as? [String: Any]); receipt["createdAt"] = NSNull(); object["receipt"] = receipt
        }
        let result = try MorningReportWire.reply(response, id: reportID, scope: owner, now: now)
        XCTAssertTrue(result.receipt.deleted); XCTAssertNil(result.receipt.createdAt); XCTAssertNil(result.document)
    }

    func testTransportErrorsNeverReplayUploadsOrExposeServerText() async throws {
        let transport = try client(), valid = try envelope()
        for reply in [MorningReportProtocol.Reply(status: 401), .init(status: 403), .init(status: 409), .init(status: 503),
                      .init(status: 302), .init(body: valid, type: "text/html"), .init(body: valid, length: "524289"),
                      .init(body: Data(repeating: 65, count: 524_289)), .init(body: valid, fail: true)] {
            MorningReportProtocol.set { _ in reply }
            do { _ = try await transport.share(id: reportID, document: document(), expectedRevision: revision); XCTFail("Invalid upload response accepted") }
            catch { XCTAssertFalse(error.localizedDescription.contains("private debug message")) }
            XCTAssertEqual(MorningReportProtocol.requests.count, 1)
        }
    }

    func testInvalidDestinationsAndExportsNeverStartARequest() async throws {
        MorningReportProtocol.set { _ in XCTFail("Invalid input sent"); return .init() }
        for address in ["http://report-fixture.invalid", "https://report-fixture.invalid/owner", "https://user:secret@report-fixture.invalid", "https://report-fixture.invalid?side=left"] {
            XCTAssertThrowsError(try client(endpoint: address))
        }
        XCTAssertThrowsError(try client(token: "secret\r\nother-header"))
        let transport = try client()
        for data in [Data(repeating: 65, count: 384 * 1024 + 1), Data(#"{"version":1,"report":{"id":"wrong"}}"#.utf8)] {
            do { _ = try await transport.share(id: reportID, document: data, expectedRevision: nil); XCTFail("Invalid export sent") } catch {}
        }
        XCTAssertTrue(MorningReportProtocol.requests.isEmpty)
    }
}

private final class MorningReportProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var body = Data("private debug message".utf8)
        var type = "application/json"
        var length: String?
        var fail = false
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: (@Sendable (URLRequest) -> Reply)?
        var requests: [URLRequest] = []
    }
    private static let state = State()
    static var requests: [URLRequest] { state.lock.withLock { state.requests } }
    static func set(_ handler: @escaping @Sendable (URLRequest) -> Reply) { state.lock.withLock { state.handler = handler; state.requests = [] } }
    static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    override static func canInit(with request: URLRequest) -> Bool { request.url?.host == "report-fixture.invalid" }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.lock.withLock { Self.state.requests.append(request); return Self.state.handler?(request) ?? .init(status: 500) }
        var headers = ["Content-Type": reply.type]
        if let length = reply.length { headers["Content-Length"] = length }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        if reply.fail { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
        else { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}
