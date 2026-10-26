import XCTest
@testable import Sleepypod

@MainActor final class BiometricDatasetTransportTests: XCTestCase {
    func testLiteralCoreSessionCapabilitiesAndPairedPageRequests() async throws {
        let http = BiometricHTTPFixture(); defer { http.close() }
        let client = CoreBiometricDatasetsClient(transport: http.transport)
        let fixture = try BiometricDatasetDemoFixture.load(side: .right)
        let descriptor = fixture.snapshots[0].descriptor
        http.state.responses = [try JSONEncoder().encode(fixture.sessions), try JSONEncoder().encode(fixture.capabilities[0]), try JSONEncoder().encode(BiometricDatasetPage(items: [descriptor], nextCursor: nil)), try JSONEncoder().encode(fixture.references)]
        let sessions = try await client.sessions(side: .right, cursor: .init(startMs: 1792706400000, id: 112))
        XCTAssertEqual(sessions.items.count, 3)
        _ = try await client.capabilities(side: .right, id: 112)
        _ = try await client.datasets(side: .right, cursor: .init(createdAtMs: 1792920000123, id: descriptor.id))
        _ = try await client.references(side: .right, cursor: nil)
        let requests = http.state.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "GET", "GET", "GET"])
        XCTAssertEqual(requests.map(\.path), ["/api/biometric-tuning/sessions", "/api/biometric-tuning/sessions/112/capabilities", "/api/biometric-tuning/datasets", "/api/biometric-tuning/references"])
        XCTAssertEqual(requests[0].query, ["side": "right", "beforeStartMs": "1792706400000", "beforeId": "112"])
        XCTAssertEqual(requests[1].query, ["side": "right"])
        XCTAssertEqual(requests[2].query, ["side": "right", "beforeCreatedAtMs": "1792920000123", "beforeId": descriptor.id])
        XCTAssertEqual(requests[3].query, ["side": "right"])
    }
    func testExactCreateAndReleaseBodiesWithoutAutomaticRetry() async throws {
        let http = BiometricHTTPFixture(); defer { http.close() }
        let client = CoreBiometricDatasetsClient(transport: http.transport)
        let fixture = try BiometricDatasetDemoFixture.load(side: .left).snapshots[0]
        let request = BiometricDatasetRequest(selection: fixture.selection, key: "stable-retry-key")
        http.state.failWrites = true
        do { _ = try await client.create(request); XCTFail("Expected unknown write") } catch {}
        XCTAssertEqual(http.state.requests.count, 1)
        let posted = http.state.requests[0]
        XCTAssertEqual(posted.path, "/api/biometric-tuning/datasets")
        XCTAssertEqual(Set(posted.body.keys), ["side", "subjectId", "sessionIds", "referenceImportIds", "idempotencyKey"])
        XCTAssertEqual(posted.body["idempotencyKey"] as? String, "stable-retry-key")
        XCTAssertNil(posted.body["timezone"])
        http.state.failWrites = false
        http.state.responses = [try JSONEncoder().encode(fixture.descriptor), try JSONEncoder().encode(fixture.descriptor)]
        _ = try await client.dataset(id: fixture.descriptor.id)
        _ = try await client.release(id: fixture.descriptor.id)
        XCTAssertEqual(http.state.requests.last?.method, "POST")
        XCTAssertEqual(http.state.requests.last?.path, "/api/biometric-tuning/datasets/\(fixture.descriptor.id)/release")
        XCTAssertTrue(http.state.requests.last?.body.isEmpty == true)
    }
    func testMalformedRequestIdentitiesAndCursorsCannotSend() async throws {
        let http = BiometricHTTPFixture(); defer { http.close() }
        let client = CoreBiometricDatasetsClient(transport: http.transport)
        do { _ = try await client.capabilities(side: .left, id: 0); XCTFail("Invalid session") } catch {}
        do { _ = try await client.sessions(side: .left, cursor: .init(startMs: .nan, id: 1)); XCTFail("Invalid cursor") } catch {}
        do { _ = try await client.datasets(side: .left, cursor: .init(createdAtMs: 1.5, id: UUID().uuidString)); XCTFail("Invalid cursor") } catch {}
        do { _ = try await client.dataset(id: "../other"); XCTFail("Invalid path") } catch {}
        do { _ = try await client.release(id: "wrong?path"); XCTFail("Invalid path") } catch {}
        XCTAssertTrue(http.state.requests.isEmpty)
    }
}
