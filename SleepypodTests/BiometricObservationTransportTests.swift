import XCTest
@testable import Sleepypod

@MainActor final class BiometricObservationTransportTests: XCTestCase {
    func testAllObservationRoutesPreserveExactPlansAndExplicitDefaults() async throws {
        let http = BiometricHTTPFixture(); defer { http.close() }
        let client = CoreBiometricObservationsClient(transport: http.transport), demo = DemoBiometricObservationsClient(profiles: .init())
        let example = try BiometricObservationExample.load(), start = (Date.now.timeIntervalSince1970 * 1000 + 300000).rounded()
        let input = BiometricObservationPreparation(templateId: "demo-plan-only", side: .right, subjectId: "Synthetic sleeper", candidateRevisionId: nil, startMs: start, endMs: start + 300000)
        let prepared = try await demo.prepare(input), templates = await demo.templates()
        let request = BiometricObservationSubmission(prepared: prepared, idempotencyKey: UUID().uuidString)
        let run = try await demo.create(request), stop = try await demo.stop(id: run.id)
        let reference = BiometricObservationReference(run: example.run, input: example.reference)
        http.state.responses = [try JSONEncoder().encode(templates), try JSONEncoder().encode(prepared), try JSONEncoder().encode(run),
                                try JSONEncoder().encode(BiometricObservationPage(items: [run], nextCursor: nil)), try JSONEncoder().encode(run),
                                try JSONEncoder().encode(stop), try JSONEncoder().encode(example.report), try JSONEncoder().encode(example.comparison)]
        _ = try await client.templates(); _ = try await client.prepare(input); _ = try await client.create(request)
        _ = try await client.list(side: .right, afterId: example.run.id); _ = try await client.get(id: run.id)
        _ = try await client.stop(id: run.id); _ = try await client.report(id: example.run.id); _ = try await client.compare(reference)
        let calls = http.state.requests
        XCTAssertEqual(calls.map(\.method), ["GET", "POST", "POST", "GET", "GET", "POST", "GET", "POST"])
        XCTAssertEqual(calls.map(\.path), ["/api/biometric-tuning/shadow-templates", "/api/biometric-tuning/shadow-plans/prepare", "/api/biometric-tuning/shadow-runs", "/api/biometric-tuning/shadow-runs",
                                           "/api/biometric-tuning/shadow-runs/\(run.id)", "/api/biometric-tuning/shadow-runs/\(run.id)/stop", "/api/biometric-tuning/shadow-runs/\(example.run.id)/report", "/api/biometric-tuning/shadow-runs/\(example.run.id)/compare"])
        XCTAssertEqual(Set(calls[1].body.keys), ["templateId", "side", "subjectId", "candidateRevisionId", "startMs", "endMs"])
        XCTAssertTrue(calls[1].body["candidateRevisionId"] is NSNull)
        XCTAssertEqual(Set(calls[2].body.keys), ["plan", "idempotencyKey"])
        let sentPlan = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(calls[2].body["plan"])))
        XCTAssertEqual(sentPlan, prepared.plan)
        XCTAssertEqual(calls[3].query, ["side": "right", "maximumRuns": "20", "afterId": example.run.id])
        XCTAssertTrue(calls[5].body.isEmpty)
        XCTAssertEqual(Set(calls[7].body.keys), ["reference"])
        let sentReference = try XCTUnwrap(calls[7].body["reference"] as? [String: Any])
        XCTAssertEqual((sentReference["timePolicy"] as? [String: String])?["disambiguation"], "reject")
        XCTAssertEqual(sentReference["subjectId"] as? String, example.run.subjectId)
    }
    func testInvalidPathsNeverSendAndUnknownWriteMakesOneAttempt() async throws {
        let http = BiometricHTTPFixture(); defer { http.close() }
        let client = CoreBiometricObservationsClient(transport: http.transport), example = try BiometricObservationExample.load()
        do { _ = try await client.get(id: "../stop"); XCTFail("Invalid path") } catch {}
        do { _ = try await client.list(side: .left, afterId: "not-a-run"); XCTFail("Invalid cursor") } catch {}
        XCTAssertTrue(http.state.requests.isEmpty)
        let request = BiometricObservationSubmission(prepared: example.prepared, idempotencyKey: UUID().uuidString)
        http.state.failWrites = true
        do { _ = try await client.create(request); XCTFail("Unknown result") } catch {}
        XCTAssertEqual(http.state.requests.count, 1)
        XCTAssertEqual(http.state.requests.first?.body["idempotencyKey"] as? String, request.idempotencyKey)
        // A retained request may be older than its original window; server idempotency resolves it first.
        XCTAssertLessThan(example.run.endMs, Date.now.timeIntervalSince1970 * 1000)
    }
}
