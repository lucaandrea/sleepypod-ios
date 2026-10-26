import XCTest
@testable import Sleepypod

@MainActor final class BiometricExperimentTransportTests: XCTestCase {
    func testLiteralExperimentRoutesCursorAndFrozenCreationBody() async throws {
        let http = BiometricHTTPFixture(); defer { http.close() }
        let client = CoreBiometricDatasetsClient(transport: http.transport)
        let parent = try BiometricDatasetDemoFixture.load(side: .left).snapshots[0].descriptor
        let request = try BiometricExperimentDraft(dataset: parent).request(key: "exact-experiment")
        let experiment = BiometricExperiment(id: UUID().uuidString.lowercased(), datasetId: parent.id, side: .left, protocol: request.protocol,
            protocolHash: String(repeating: "a", count: 64), holdoutAccesses: 0, createdAtMs: 1792706400000)
        http.state.responses = [try JSONEncoder().encode(BiometricExperimentPage(items: [experiment], nextCursor: nil)), try JSONEncoder().encode(experiment), try JSONEncoder().encode(experiment)]
        _ = try await client.experiments(side: .left, cursor: .init(createdAtMs: experiment.createdAtMs, id: experiment.id))
        _ = try await client.experiment(id: experiment.id); _ = try await client.create(request)
        let requests = http.state.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "GET", "POST"])
        XCTAssertEqual(requests.map(\.path), ["/api/biometric-tuning/experiments", "/api/biometric-tuning/experiments/\(experiment.id)", "/api/biometric-tuning/experiments"])
        XCTAssertEqual(requests[0].query, ["side": "left", "beforeCreatedAtMs": "1792706400000", "beforeId": experiment.id])
        XCTAssertEqual(Set(requests[2].body.keys), ["datasetId", "protocol", "idempotencyKey"])
        XCTAssertEqual(requests[2].body["idempotencyKey"] as? String, request.idempotencyKey)
        let protocolBody = try XCTUnwrap(requests[2].body["protocol"] as? [String: Any])
        XCTAssertNil(protocolBody["waveformStages"]); XCTAssertNil(protocolBody["nightUncertainty"])
    }
    func testInvalidIdentityAndUnpairedCursorCannotSend() async throws {
        let http = BiometricHTTPFixture(); defer { http.close() }
        let client = CoreBiometricDatasetsClient(transport: http.transport)
        do { _ = try await client.experiment(id: "../other"); XCTFail("Invalid identity") } catch {}
        do { _ = try await client.experiments(side: .left, cursor: .init(createdAtMs: .nan, id: UUID().uuidString)); XCTFail("Invalid date") } catch {}
        do { _ = try await client.experiments(side: .left, cursor: .init(createdAtMs: 12, id: "../other")); XCTFail("Invalid cursor") } catch {}
        XCTAssertTrue(http.state.requests.isEmpty)
    }
    func testUnknownCreationMakesOneAttemptWithOriginalKey() async throws {
        let http = BiometricHTTPFixture(); defer { http.close() }
        let client = CoreBiometricDatasetsClient(transport: http.transport)
        let request = try BiometricExperimentDraft(dataset: BiometricDatasetDemoFixture.load(side: .left).snapshots[0].descriptor).request(key: "unknown-protocol")
        http.state.failWrites = true
        do { _ = try await client.create(request); XCTFail("Expected lost response") } catch {}
        XCTAssertEqual(http.state.requests.count, 1)
        XCTAssertEqual(http.state.requests.first?.body["idempotencyKey"] as? String, request.idempotencyKey)
    }
}
