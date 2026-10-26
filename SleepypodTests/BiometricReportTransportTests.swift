import XCTest
@testable import Sleepypod

@MainActor final class BiometricReportTransportTests: XCTestCase {
    func testNullableSummaryRawReleaseAndExactTraceRoutes() async throws {
        let http = BiometricHTTPFixture(); defer { http.close() }
        let example = try XCTUnwrap(BiometricReportExample.load().first { $0.name == "signal_replay" })
        let client = CoreBiometricReportsClient(transport: http.transport)
        let stage = try XCTUnwrap(example.stagePages.first), numeric = try XCTUnwrap(example.numericPages.first), reference = try XCTUnwrap(example.referencePages.first)
        let receipt = BiometricReportReleaseReceipt(jobId: example.id, contentHash: example.summary.contentHash, available: false, releasedAtMs: 1793000000000)
        http.state.responses = [Data("null".utf8), try JSONEncoder().encode(receipt), try JSONEncoder().encode(stage), try JSONEncoder().encode(numeric), try JSONEncoder().encode(reference)]
        let missing = try await client.summary(id: example.id); XCTAssertNil(missing)
        let released = try await client.release(id: example.id, expectedHash: example.summary.contentHash)
        XCTAssertTrue(released?.confirms(id: example.id, hash: example.summary.contentHash) == true)
        let selection = BiometricTraceSelection(jobId: example.id, contentHash: example.summary.contentHash, configuration: .defaults, cohortId: "night", offset: 3, limit: 3)
        _ = try await client.stages(selection); _ = try await client.numeric(selection); _ = try await client.references(selection, metric: .heartRate)
        let sent = http.state.requests, root = "/api/biometric-tuning/backtests/\(example.id)"
        XCTAssertEqual(sent.map(\.method), ["GET", "POST", "GET", "GET", "GET"])
        XCTAssertEqual(sent.map(\.path), [root + "/summary", root + "/result/release", root + "/trace", root + "/numeric-trace", root + "/reference-trace"])
        XCTAssertEqual(Set(sent[1].body.keys), ["expectedContentHash"])
        XCTAssertEqual(sent[1].body["expectedContentHash"] as? String, example.summary.contentHash)
        XCTAssertEqual(sent[2].query, ["expectedContentHash": example.summary.contentHash, "configuration": "default", "cohortId": "night", "offset": "3", "limit": "3"])
        XCTAssertEqual(sent[3].query, sent[2].query)
        XCTAssertEqual(sent[4].query, ["expectedContentHash": example.summary.contentHash, "metric": "heart_rate", "cohortId": "night", "offset": "3", "limit": "3"])
    }
    func testInvalidReportIdentitiesHashesAndCursorsNeverSend() async throws {
        let http = BiometricHTTPFixture(); defer { http.close() }
        let client = CoreBiometricReportsClient(transport: http.transport), identity = UUID().uuidString
        do { _ = try await client.summary(id: "../other"); XCTFail("Invalid path") } catch {}
        do { _ = try await client.release(id: identity, expectedHash: "changed"); XCTFail("Invalid hash") } catch {}
        for offset in [-1, 1000001] {
            let selected = BiometricTraceSelection(jobId: identity, contentHash: String(repeating: "a", count: 64), cohortId: "night", offset: offset)
            do { _ = try await client.numeric(selected); XCTFail("Invalid cursor") } catch {}
        }
        XCTAssertTrue(http.state.requests.isEmpty)
    }
    func testUnknownReleaseIsOneRequestWithReviewedHash() async throws {
        let http = BiometricHTTPFixture(); defer { http.close() }
        let client = CoreBiometricReportsClient(transport: http.transport), hash = String(repeating: "a", count: 64)
        http.state.failWrites = true
        do { _ = try await client.release(id: UUID().uuidString, expectedHash: hash); XCTFail("Unknown response") } catch {}
        XCTAssertEqual(http.state.requests.count, 1)
        XCTAssertEqual(http.state.requests[0].body["expectedContentHash"] as? String, hash)
    }
}
