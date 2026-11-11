import XCTest
@testable import Sleepypod

@MainActor final class TargetResponseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_312_000)
    func testCoreGeneratedFixtureAndIndependentNightGroups() throws {
        let fixture = try TargetResponseExampleFile.load()
        XCTAssertTrue(fixture.synthetic); XCTAssertEqual(fixture.sourceCommit.count, 40)
        try fixture.status.validate(side: .left, now: Date(timeIntervalSince1970: fixture.now / 1000))
        let model = try XCTUnwrap(fixture.status.model)
        XCTAssertEqual(model.trainingDates.count, 10); XCTAssertEqual(model.calibrationDates.count, 5); XCTAssertEqual(model.validationDates.count, 5)
        XCTAssertTrue(model.passed); XCTAssertTrue(fixture.status.canPreview); XCTAssertFalse(fixture.status.canEvaluate)
        XCTAssertFalse(fixture.status.activationAvailable)
    }
    func testMalformedIdentityCountsClocksAndEvidenceCannotAppearReady() throws {
        for field in ["apiVersion", "side", "generatedAt", "requiredNights", "datasetHash", "activationAvailable", "completeNights", "evidence"] {
            let value = try modified { object in
                switch field {
                case "apiVersion": object[field] = 2
                case "side": object[field] = "right"
                case "generatedAt": object[field] = self.now.addingTimeInterval(1).timeIntervalSince1970 * 1000
                case "requiredNights": object[field] = 1
                case "datasetHash": object[field] = "wrong"
                case "activationAvailable": object[field] = true
                case "completeNights": object[field] = 19
                case "evidence": var evidence = try XCTUnwrap(object[field] as? [String: Any]); evidence["status"] = "partial"; object[field] = evidence
                default: break
                }
            }
            XCTAssertThrowsError(try value.validate(side: .left, now: now), field)
        }
    }
    func testInvalidSplitOrDishonestPassingScoreIsRejected() throws {
        for field in ["trainingDates", "createdAt", "sourceLastAt", "horizons", "scores", "configuration"] {
            let value = try modified { object in
                var model = try XCTUnwrap(object["model"] as? [String: Any])
                switch field {
                case "trainingDates": model[field] = Array(repeating: "2026-10-01", count: 10)
                case "createdAt": model[field] = self.now.addingTimeInterval(1).timeIntervalSince1970 * 1000
                case "sourceLastAt": model[field] = self.now.addingTimeInterval(-31 * 86400).timeIntervalSince1970 * 1000
                case "configuration": model[field] = "invalid"
                case "horizons": model[field] = []
                case "scores":
                    var horizons = try XCTUnwrap(model["horizons"] as? [[String: Any]])
                    var scores = try XCTUnwrap(horizons[0]["validation"] as? [String: Any]); scores["modelMaeF"] = 1.2
                    horizons[0]["validation"] = scores; model["horizons"] = horizons
                default: break
                }
                object["model"] = model
            }
            XCTAssertThrowsError(try value.validate(side: .left, now: now), field)
        }
    }
    func testPreviewRejectsWrongSideFutureExpiryDuplicatesAndBrokenBands() throws {
        let value = TargetResponseExample.previewValue(now: now)
        try value.validate(side: .left, now: now)
        XCTAssertThrowsError(try value.validate(side: .right, now: now))
        XCTAssertThrowsError(try value.validate(side: .left, now: now.addingTimeInterval(-1)))
        XCTAssertThrowsError(try value.validate(side: .left, now: now.addingTimeInterval(90)))
        for field in ["duplicate", "horizon", "range", "activation"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            var candidates = try XCTUnwrap(object["candidates"] as? [[String: Any]])
            if field == "duplicate" { candidates[1] = candidates[0] }
            if field == "horizon" { candidates[0]["predictions"] = [] as [[String: Any]]; candidates[1]["predictions"] = [["minutes": 15, "waterF": 70, "lowerF": 69, "upperF": 71]] }
            if field == "range" {
                var predictions = try XCTUnwrap(candidates[0]["predictions"] as? [[String: Any]])
                predictions[0]["lowerF"] = 80; candidates[0]["predictions"] = predictions
            }
            if field == "activation" { object["activationAvailable"] = true }
            object["candidates"] = candidates
            let result = try JSONDecoder().decode(TargetResponsePreview.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try result.validate(side: .left, now: now), field)
        }
    }
    func testExplicitFlowFitsOnlyOnceAndKeepsPreviewSeparate() async throws {
        let client = ResponseTestClient(now: now)
        let workspace = TargetResponseWorkspace(currentOwner: { ["owner"] }, now: { self.now })
        workspace.configure(client: client, side: .left)
        await workspace.evaluate(); await workspace.readPreview()
        let initial = await client.counts(); XCTAssertEqual(initial, [0, 0, 0])
        await workspace.refresh()
        XCTAssertTrue(workspace.status(at: now)?.canEvaluate == true); XCTAssertNil(workspace.preview(at: now))
        await workspace.evaluate(); await workspace.evaluate()
        XCTAssertNotNil(workspace.notice); XCTAssertNil(workspace.preview(at: now))
        await workspace.readPreview()
        XCTAssertEqual(workspace.preview(at: now)?.candidates.count, 2)
        let counts = await client.counts(); XCTAssertEqual(counts, [1, 1, 1])
    }
    func testExpiredEvidenceAndOwnerChangeWithdrawImmediately() async throws {
        var owner: [String]? = ["owner"]
        let client = ResponseTestClient(now: now), workspace = TargetResponseWorkspace(currentOwner: { owner }, now: { self.now })
        workspace.configure(client: client, side: .left); await workspace.refresh(); await workspace.evaluate(); await workspace.readPreview()
        XCTAssertNil(workspace.preview(at: now.addingTimeInterval(90)))
        XCTAssertNil(workspace.status(at: now.addingTimeInterval(300)))
        owner = ["another"]
        XCTAssertNil(workspace.status(at: now)); XCTAssertNil(workspace.preview(at: now))
        await workspace.refresh()
        let counts = await client.counts(); XCTAssertEqual(counts, [1, 1, 1])
    }
    func testUnconfirmedFitRequiresReadbackAndIsNotRetried() async throws {
        let client = ResponseTestClient(now: now), workspace = TargetResponseWorkspace(currentOwner: { ["owner"] }, now: { self.now })
        workspace.configure(client: client, side: .left); await workspace.refresh()
        await client.failFitReply(); await workspace.evaluate(); await workspace.evaluate()
        XCTAssertNil(workspace.status(at: now)); XCTAssertTrue(workspace.error?.contains("not repeat") == true)
        let counts = await client.counts(); XCTAssertEqual(counts, [1, 1, 0])
        await workspace.refresh()
        XCTAssertTrue(workspace.status(at: now)?.canPreview == true)
        XCTAssertFalse(workspace.status(at: now)?.canEvaluate == true)
    }
    func testUnavailableSourceWithdrawsOldValuesAndPersonalBoundaryDoesNotRead() async throws {
        let client = ResponseTestClient(now: now), workspace = TargetResponseWorkspace(currentOwner: { ["owner"] }, now: { self.now })
        workspace.configure(client: client, side: .left); await workspace.refresh()
        await client.failReads(); await workspace.refresh()
        XCTAssertNil(workspace.status(at: now)); XCTAssertNotNil(workspace.error)
        let personal = TargetResponseWorkspace(currentOwner: { nil }, now: { self.now })
        personal.configure(client: client, side: .left); await personal.refresh()
        let counts = await client.counts(); XCTAssertEqual(counts, [2, 0, 0])
    }
    func testLateReadsCannotCrossSideAccountOrCancellation() async throws {
        for change in ["side", "owner", "cancel"] {
            let client = DelayedResponseClient(), value = try TargetResponseExample.value(now: now)
            var owner: [String]? = ["owner"]
            let workspace = TargetResponseWorkspace(currentOwner: { owner }, now: { self.now })
            workspace.configure(client: client, side: .left)
            let task = Task { await workspace.refresh() }; await client.waitUntilStarted()
            if change == "side" { workspace.configure(client: client, side: .right) }
            else if change == "owner" { owner = ["changed"] } else { task.cancel() }
            await client.finish(value); await task.value
            XCTAssertNil(workspace.status(at: now)); XCTAssertNil(workspace.operation)
        }
    }
    func testTemperatureDifferencesDoNotSubtractTheCelsiusOrigin() {
        XCTAssertEqual(TargetResponseTemperature.converted(69.8, celsius: true), 21, accuracy: 0.001)
        XCTAssertEqual(TargetResponseTemperature.converted(0.9, celsius: true, difference: true), 0.5, accuracy: 0.001)
        XCTAssertEqual(TargetResponseTemperature.converted(0.9, celsius: false, difference: true), 0.9)
    }
    func testMissingControllerExplainsRecoveryWithoutIssuingARequest() async {
        let workspace = TargetResponseWorkspace(currentOwner: { ["owner"] }, now: { self.now })
        workspace.configure(client: nil, side: .left); await workspace.refresh()
        XCTAssertNil(workspace.status(at: now)); XCTAssertTrue(workspace.error?.contains("updated Sleepypod Core") == true)
    }
    func testRESTUsesExactResearchRoutesAndOnlyTheReviewedDigest() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ResponseFixtureProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let transport = CoreRESTClient(endpoint: try XCTUnwrap(URL(string: "http://127.0.0.1:3000")), session: session)
        let client = CoreTargetResponseClient(transport: transport)
        let read = try await client.status(side: .left)
        XCTAssertEqual(read.side, .left)
        _ = try await client.evaluate(side: .left, datasetHash: String(repeating: "a", count: 64))
        _ = try await client.preview(side: .left)
        do { _ = try await client.evaluate(side: .left, datasetHash: "invalid"); XCTFail("Bad digest must not be submitted") } catch {}
    }
    private func modified(_ edit: (inout [String: Any]) throws -> Void) throws -> TargetResponseResearch {
        let value = try TargetResponseExample.value(fitted: true, now: now)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        try edit(&object)
        return try JSONDecoder().decode(TargetResponseResearch.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

private actor ResponseTestClient: TargetResponseClient {
    let now: Date
    var fitted = false
    var fitReplyFails = false
    var readFails = false
    var reads = 0, fits = 0, previews = 0
    init(now: Date) { self.now = now }
    func counts() -> [Int] { [reads, fits, previews] }
    func failFitReply() { fitReplyFails = true }
    func failReads() { readFails = true }
    func status(side: Side) throws -> TargetResponseResearch {
        reads += 1
        if readFails { throw URLError(.notConnectedToInternet) }
        return try TargetResponseExample.value(side: side, fitted: fitted, now: now)
    }
    func evaluate(side: Side, datasetHash: String) throws -> TargetResponseResearch {
        fits += 1; fitted = true
        XCTAssertEqual(datasetHash, String(repeating: "a", count: 64))
        if fitReplyFails { throw URLError(.timedOut) }
        return try TargetResponseExample.value(side: side, fitted: true, now: now)
    }
    func preview(side: Side) -> TargetResponsePreview { previews += 1; return TargetResponseExample.previewValue(side: side, now: now) }
}

private actor DelayedResponseClient: TargetResponseClient {
    var continuation: CheckedContinuation<TargetResponseResearch, Never>?
    func status(side: Side) async -> TargetResponseResearch { await withCheckedContinuation { continuation = $0 } }
    func evaluate(side: Side, datasetHash: String) throws -> TargetResponseResearch { throw TargetResponseResearch.invalid }
    func preview(side: Side) throws -> TargetResponsePreview { throw TargetResponseResearch.invalid }
    func waitUntilStarted() async { while continuation == nil { await Task.yield() } }
    func finish(_ value: TargetResponseResearch) { continuation?.resume(returning: value); continuation = nil }
}

private final class ResponseFixtureProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url), data: Data
            switch url.path {
            case "/api/v1/comfort/response/model", "/api/v1/comfort/response/preview":
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "side", value: "left")])
                data = url.path.hasSuffix("preview") ? try JSONEncoder().encode(TargetResponseExample.previewValue())
                    : try JSONEncoder().encode(TargetResponseExample.value())
            case "/api/v1/comfort/response/train":
                XCTAssertEqual(request.httpMethod, "POST"); XCTAssertNil(url.query)
                var body = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count)) }
                }
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
                XCTAssertEqual(object, ["side": "left", "expectedDatasetHash": String(repeating: "a", count: 64)])
                data = try JSONEncoder().encode(TargetResponseExample.value(fitted: true))
            default: throw TargetResponseResearch.invalid
            }
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
