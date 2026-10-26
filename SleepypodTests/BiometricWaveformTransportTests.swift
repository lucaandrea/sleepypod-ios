import XCTest
@testable import Sleepypod

@MainActor final class BiometricWaveformTransportTests: XCTestCase {
    func testLiteralArchiveRoutesCursorsAndExplicitNullScanBody() async throws {
        let http = BiometricHTTPFixture(); defer { http.close() }
        let client = CoreBiometricDatasetsClient(transport: http.transport)
        let fixture = try XCTUnwrap(BiometricWaveformDemoFixture.load().first), page = try XCTUnwrap(fixture.pages.first?.page)
        let source = try XCTUnwrap(page.items.first), name = source.inspection.sourceName
        http.state.responses = [try JSONEncoder().encode(ReplayAdmission(configured: true, qualificationId: "fixture", admitted: true, reasons: [])),
            try JSONEncoder().encode(page), try JSONEncoder().encode(RawInspectionResult(status: .inspected, nextCursor: name, source: source)),
            try JSONEncoder().encode(RawInspectionResult(status: .complete, nextCursor: nil, source: nil)),
            try JSONEncoder().encode(WaveformDatasetResponse(status: .published, dataset: fixture.descriptor))]
        _ = try await client.replayAdmission()
        _ = try await client.rawSources(startMs: 1792706100000, endMs: 1792713600000, cursor: source.id)
        _ = try await client.inspectRaw(afterName: nil); _ = try await client.inspectRaw(afterName: name)
        _ = try await client.createWaveform(fixture.request)
        let requests = http.state.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "GET", "POST", "POST", "POST"])
        XCTAssertEqual(requests.map(\.path), ["/api/biometric-tuning/replay-admission", "/api/biometric-tuning/raw-sources", "/api/biometric-tuning/raw-sources/inspect", "/api/biometric-tuning/raw-sources/inspect", "/api/biometric-tuning/waveform-datasets"])
        XCTAssertEqual(requests[1].query, ["startMs": "1792706100000", "endMs": "1792713600000", "afterId": source.id])
        XCTAssertTrue(requests[2].body["afterName"] is NSNull)
        XCTAssertEqual(requests[3].body["afterName"] as? String, name)
        XCTAssertEqual(Set(requests[4].body.keys), ["parentDatasetId", "expectedContentHash", "cohorts", "idempotencyKey"])
        XCTAssertEqual(requests[4].body["expectedContentHash"] as? String, fixture.request.expectedContentHash)
    }
    func testInvalidPathsWindowsAndDuplicateSelectionsCannotSend() async throws {
        let http = BiometricHTTPFixture(); defer { http.close() }
        let client = CoreBiometricDatasetsClient(transport: http.transport)
        do { _ = try await client.rawSources(startMs: 5, endMs: 5, cursor: nil); XCTFail("Empty window") } catch {}
        do { _ = try await client.rawSources(startMs: .nan, endMs: 10, cursor: nil); XCTFail("Invalid window") } catch {}
        do { _ = try await client.rawSources(startMs: 0, endMs: 10, cursor: "../other"); XCTFail("Invalid cursor") } catch {}
        do { _ = try await client.inspectRaw(afterName: "../escape.RAW.gz"); XCTFail("Invalid scan") } catch {}
        let fixture = try XCTUnwrap(BiometricWaveformDemoFixture.load().first), selected = try XCTUnwrap(fixture.request.cohorts.first)
        let request = WaveformDatasetRequest(parentDatasetId: fixture.parentId, expectedContentHash: fixture.request.expectedContentHash, cohorts: [selected, selected], idempotencyKey: "same-night-twice")
        do { _ = try await client.createWaveform(request); XCTFail("Duplicate selection") } catch {}
        XCTAssertTrue(http.state.requests.isEmpty)
    }
    func testUnknownPublicationIsOneTransportAttempt() async throws {
        let http = BiometricHTTPFixture(); defer { http.close() }
        let client = CoreBiometricDatasetsClient(transport: http.transport)
        let fixture = try XCTUnwrap(BiometricWaveformDemoFixture.load().first)
        http.state.failWrites = true
        do { _ = try await client.createWaveform(fixture.request); XCTFail("Expected unknown result") } catch {}
        XCTAssertEqual(http.state.requests.count, 1)
        XCTAssertEqual(http.state.requests.first?.body["idempotencyKey"] as? String, fixture.request.idempotencyKey)
    }
}
