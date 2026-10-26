import XCTest
@testable import Sleepypod

@MainActor final class NativeControlRESTTests: XCTestCase {
    private func transport(_ host: String) -> CoreRESTClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [NativeActionRequestProtocol.self]
        return .init(endpoint: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration))
    }
    func testCapabilitiesSubmitAndReadUseExactImmutableEnvelope() async throws {
        let transport = transport("actions-contract.invalid"); defer { transport.session.invalidateAndCancel() }
        let client = CoreNativeControlClient(transport: transport); try await client.available()
        let request = try NativeControlRequest(action: .init(kind: "temperature", side: .right, temperature: 68, holdMinutes: 30), requestId: NativeActionRequestProtocol.requestID)
        let result = try await client.submit(request); XCTAssertEqual(result.state, "acknowledged")
        let read = try await client.read(request); XCTAssertEqual(read, result)
    }
    func testUnsupportedReceiptContractAndPrivateHTTPErrorAreRejected() async throws {
        for host in ["actions-unsupported.invalid", "actions-key.invalid"] {
            let transport = transport(host); defer { transport.session.invalidateAndCancel() }
            do { try await CoreNativeControlClient(transport: transport).available(); XCTFail("Expected failure") }
            catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE")) }
        }
    }
    func testPersonalReadsUseFahrenheitAndTargetedWritesDoNotUseLegacyRoutes() async throws {
        let transport = transport("actions-personal.invalid"); defer { transport.session.invalidateAndCancel() }
        let client = CoreNativePersonalActionClient(transport: transport)
        let current = try await client.temperature(side: .left, current: true), target = try await client.temperature(side: .right, current: false)
        XCTAssertEqual(current, 68.5); XCTAssertEqual(target, 82)
        try await client.away(side: .right, enabled: true); try await client.prime()
    }
    func testStaleNullAndWrongSideRepliesNeverSubstituteValues() async throws {
        for host in ["actions-stale.invalid", "actions-null.invalid", "actions-wrong-side.invalid"] {
            let transport = transport(host); defer { transport.session.invalidateAndCancel() }
            let client = CoreNativePersonalActionClient(transport: transport)
            do {
                if host.contains("wrong-side") { try await client.away(side: .right, enabled: true) }
                else { _ = try await client.temperature(side: .left, current: true) }
                XCTFail("Do not accept missing or inconsistent data")
            } catch {}
        }
    }
}
private final class NativeActionRequestProtocol: URLProtocol, @unchecked Sendable {
    static let requestID = UUID(uuidString: "aabbccdd-0000-4000-8000-111111111111")!
    private static let lock = NSLock()
    nonisolated(unsafe) private static var receipt: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = request.url!, host = url.host!, method = request.httpMethod
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            var valid = request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData, status = 200
            var payload: [String: Any] = [:]
            if host.contains("key") { status = 401; payload = ["message": "PRIVATE"] }
            else if url.path == "/api/v1/capabilities" {
                valid = valid && method == "GET" && query.isEmpty
                payload = ["apiVersion": 1, "generatedAt": "2026-10-26T12:00:00.000Z", "observations": ["device": ["freshness": host.contains("stale") ? "stale" : "fresh", "expiresAt": "2026-10-26T12:00:15.000Z"]],
                    "endpoints": ["controls": host.contains("unsupported") ? "https://external.invalid/control" : "/api/v1/controls"],
                    "controlSemantics": ["durableCommandReceipts": true, "commandExpiry": true, "receiptScope": "versioned_controls_only", "maxLifetimeMs": 60000]]
            } else if url.path == "/api/v1/controls", method == "POST" {
                let data = try body(), input = try JSONDecoder().decode(NativeControlRequest.self, from: data)
                let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                valid = valid && query.isEmpty && Set(object.keys) == ["requestId", "issuedAt", "expiresAt", "action"]
                    && object["requestId"] as? String == Self.requestID.uuidString.lowercased()
                    && input.action == .init(kind: "temperature", side: .right, temperature: 68, holdMinutes: 30)
                    && input.expiresAt - input.issuedAt == 30000
                let value = NativeControlReceipt(version: 1, requestId: input.requestId, action: input.action, issuedAt: input.issuedAt, expiresAt: input.expiresAt,
                    receivedAt: input.issuedAt, finishedAt: input.issuedAt + 1, lastDispatchAt: input.issuedAt, state: "acknowledged", reason: nil, dispatchCount: 1, physicalVerification: "unverified", replayAllowed: false)
                let receipt = try JSONEncoder().encode(value); Self.lock.withLock { Self.receipt = receipt }
                payload = try JSONSerialization.jsonObject(with: receipt) as! [String: Any]
            } else if url.path == "/api/v1/controls/\(Self.requestID.uuidString.lowercased())", method == "GET" {
                valid = valid && query.isEmpty
                payload = try JSONSerialization.jsonObject(with: Self.lock.withLock { Self.receipt! }) as! [String: Any]
            } else if url.path == "/api/device/status", method == "GET" {
                valid = valid && query == ["unit": "F"]
                payload = ["leftSide": ["currentTemperature": host.contains("null") ? NSNull() as Any : 68.5 as Any, "targetTemperature": 80], "rightSide": ["currentTemperature": 70, "targetTemperature": 82]]
            } else if url.path == "/api/settings/side", method == "PATCH" {
                let fields = try JSONSerialization.jsonObject(with: body()) as! NSDictionary
                valid = valid && fields == ["side": "right", "awayMode": true] as NSDictionary
                payload = ["side": host.contains("wrong-side") ? "left" : "right", "awayMode": true]
            } else if url.path == "/api/device/prime", method == "POST" {
                let fields = try JSONSerialization.jsonObject(with: body()) as? NSDictionary
                valid = valid && fields == [:] as NSDictionary
                payload = ["success": true]
            } else { valid = false }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: valid ? status : 422, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: payload)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func body() throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { throw NativeControlFailure.invalid }
        stream.open(); defer { stream.close() }; var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); guard count >= 0 else { throw NativeControlFailure.invalid }; if count == 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
        return data
    }
    override func stopLoading() {}
}
