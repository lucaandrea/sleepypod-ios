import XCTest
@testable import Sleepypod

@MainActor final class BiometricValidatedTransportTests: XCTestCase {
    func testReviewAndApplySendOnlyServerContractFields() async throws {
        let http = BiometricHTTPFixture(); defer { http.close() }
        let client = CoreBiometricProfilesClient(transport: http.transport)
        let selection = BiometricValidatedSelection(side: .right, revisionId: UUID().uuidString, expectedResolvedHash: String(repeating: "a", count: 64), evaluationId: UUID().uuidString, expectedReportHash: String(repeating: "b", count: 64))
        let review = BiometricValidatedReviewRequest(selection: selection, expectedGeneration: 12)
        let request = BiometricValidatedRequest(review: review, boundary: .nextSession, requester: "ios-calibration", idempotencyKey: UUID().uuidString)
        let event = BiometricActivationEvent(id: UUID().uuidString, side: .right, generation: 13, action: "activate", previousRevisionId: nil, nextRevisionId: selection.revisionId, previousHash: String(repeating: "c", count: 64), nextHash: selection.expectedResolvedHash, evaluationId: selection.evaluationId, evidence: .object(["status": .string("validated_reference_agreement"), "version": .string("verified-evaluation-v1"), "reportHash": .string(selection.expectedReportHash), "revisionId": .string(selection.revisionId), "resolvedHash": .string(selection.expectedResolvedHash)]), requester: request.requester, state: "saved", reason: nil, createdAtMs: 1793000000000, updatedAtMs: 1793000000000)
        http.state.responses = [Data("{\"eligible\":true}".utf8), try JSONEncoder().encode(event)]
        let eligibility = try await client.reviewValidated(review); XCTAssertTrue(eligibility.eligible)
        let receipt = try await client.activateValidated(request); XCTAssertTrue(request.confirms(receipt))
        let sent = http.state.requests
        XCTAssertEqual(sent.map(\.method), ["GET", "POST"])
        XCTAssertEqual(sent.map(\.path), ["/api/biometric-tuning/validated-activation-review", "/api/biometric-tuning/activate-validated"])
        XCTAssertEqual(sent[0].query, ["side": "right", "revisionId": selection.revisionId, "expectedResolvedHash": selection.expectedResolvedHash, "evaluationId": selection.evaluationId, "expectedReportHash": selection.expectedReportHash, "expectedGeneration": "12"])
        XCTAssertEqual(Set(sent[1].body.keys), ["side", "revisionId", "expectedResolvedHash", "evaluationId", "expectedReportHash", "expectedGeneration", "boundary", "requester", "idempotencyKey"])
        XCTAssertEqual(sent[1].body["expectedGeneration"] as? Int, 12)
        XCTAssertEqual(sent[1].body["boundary"] as? String, "next_session")
        XCTAssertEqual(sent[1].body["idempotencyKey"] as? String, request.idempotencyKey)
        XCTAssertEqual(sent[1].body["expectedReportHash"] as? String, selection.expectedReportHash)
    }
    func testInvalidSelectionsAndUnknownResultsDoNotAutomaticallyRetry() async throws {
        let http = BiometricHTTPFixture(); defer { http.close() }
        let client = CoreBiometricProfilesClient(transport: http.transport), hash = String(repeating: "a", count: 64)
        let invalid = BiometricValidatedSelection(side: .left, revisionId: "../profiles", expectedResolvedHash: hash, evaluationId: UUID().uuidString, expectedReportHash: hash)
        do { _ = try await client.reviewValidated(.init(selection: invalid, expectedGeneration: 0)); XCTFail("Invalid selection") } catch {}
        let valid = BiometricValidatedSelection(side: .left, revisionId: UUID().uuidString, expectedResolvedHash: hash, evaluationId: UUID().uuidString, expectedReportHash: hash)
        for generation in [-1, Int.max] {
            do { _ = try await client.reviewValidated(.init(selection: valid, expectedGeneration: generation)); XCTFail("Invalid generation") } catch {}
        }
        XCTAssertTrue(http.state.requests.isEmpty)
        let request = BiometricValidatedRequest(review: .init(selection: valid, expectedGeneration: 0), boundary: .immediate, requester: "unit-test", idempotencyKey: UUID().uuidString)
        http.state.failWrites = true
        do { _ = try await client.activateValidated(request); XCTFail("Unknown result") } catch {}
        XCTAssertEqual(http.state.requests.count, 1)
        XCTAssertEqual(http.state.requests.first?.body["idempotencyKey"] as? String, request.idempotencyKey)
    }
}
