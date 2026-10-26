import XCTest
@testable import Sleepypod

@MainActor final class BiometricBacktestJobTransportTests: XCTestCase {
    func testQueueAndCancelUseExactPublicRoutesAndBodies() async throws {
        let http = BiometricHTTPFixture(); defer { http.close() }
        let client = CoreBiometricDatasetsClient(transport: http.transport), job = fixture()
        let request = BiometricBacktestSubmission(experimentId: job.experimentId, candidateRevisionId: try XCTUnwrap(job.configurations.first?.revisionId), expectedBindingGeneration: 7, split: .tuning, idempotencyKey: "exact-queue")
        http.state.responses = [try JSONEncoder().encode(BiometricBacktestPage(items: [job], nextCursor: nil)), try JSONEncoder().encode(job), try JSONEncoder().encode(job), try JSONEncoder().encode(job)]
        _ = try await client.jobs(side: .right, cursor: .init(createdAtMs: job.createdAtMs, id: job.id))
        _ = try await client.job(id: job.id); _ = try await client.submit(request); _ = try await client.cancelJob(id: job.id)
        let sent = http.state.requests
        XCTAssertEqual(sent.map(\.method), ["GET", "GET", "POST", "POST"])
        XCTAssertEqual(sent.map(\.path), ["/api/biometric-tuning/backtests", "/api/biometric-tuning/backtests/\(job.id)", "/api/biometric-tuning/backtests", "/api/biometric-tuning/backtests/\(job.id)/cancel"])
        XCTAssertEqual(sent[0].query, ["side": "right", "beforeCreatedAtMs": "1792706400000", "beforeId": job.id])
        XCTAssertEqual(Set(sent[2].body.keys), ["experimentId", "candidateRevisionId", "expectedBindingGeneration", "split", "idempotencyKey"])
        XCTAssertEqual(sent[2].body["expectedBindingGeneration"] as? Int, 7)
        XCTAssertEqual(sent[2].body["idempotencyKey"] as? String, "exact-queue")
        XCTAssertTrue(sent[3].body.isEmpty)
    }
    func testInvalidPathsAndNegativeGenerationsNeverSend() async throws {
        let http = BiometricHTTPFixture(); defer { http.close() }
        let client = CoreBiometricDatasetsClient(transport: http.transport)
        do { _ = try await client.job(id: "../other"); XCTFail("Bad identity") } catch {}
        do { _ = try await client.cancelJob(id: "../other"); XCTFail("Bad identity") } catch {}
        do { _ = try await client.jobs(side: .left, cursor: .init(createdAtMs: .infinity, id: UUID().uuidString)); XCTFail("Bad cursor") } catch {}
        do { _ = try await client.submit(.init(experimentId: UUID().uuidString, candidateRevisionId: UUID().uuidString, expectedBindingGeneration: -1, split: .tuning, idempotencyKey: "negative")); XCTFail("Bad generation") } catch {}
        XCTAssertTrue(http.state.requests.isEmpty)
    }
    func testUnknownQueueIsOneAttemptWithOriginalGenerationAndKey() async throws {
        let http = BiometricHTTPFixture(); defer { http.close() }
        let client = CoreBiometricDatasetsClient(transport: http.transport)
        let request = BiometricBacktestSubmission(experimentId: UUID().uuidString, candidateRevisionId: UUID().uuidString, expectedBindingGeneration: 12, split: .holdout, idempotencyKey: "held-attempt")
        http.state.failWrites = true
        do { _ = try await client.submit(request); XCTFail("Expected unknown response") } catch {}
        XCTAssertEqual(http.state.requests.count, 1)
        XCTAssertEqual(http.state.requests[0].body["expectedBindingGeneration"] as? Int, 12)
        XCTAssertEqual(http.state.requests[0].body["idempotencyKey"] as? String, "held-attempt")
    }
    private func fixture() -> BiometricBacktestJob {
        .init(id: UUID().uuidString.lowercased(), experimentId: UUID().uuidString.lowercased(), state: .queued, attempt: 0,
            progress: .init(phase: "queued", completedNights: 0, totalNights: 2), cancellationRequestedAtMs: nil, error: nil,
            createdAtMs: 1792706400000, updatedAtMs: 1792706400000, datasetId: UUID().uuidString.lowercased(), datasetHash: String(repeating: "b", count: 64),
            evaluatorBuildHash: String(repeating: "c", count: 64), split: .tuning, configurations: [.init(label: "candidate", revisionId: UUID().uuidString.lowercased(), hash: String(repeating: "d", count: 64))], evaluationScope: .comparison)
    }
}
