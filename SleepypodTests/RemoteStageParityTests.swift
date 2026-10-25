import XCTest
@testable import Sleepypod

@MainActor final class RemoteStageParityTests: XCTestCase {
    private func defaults() throws -> RemoteStageClassifier { try StageFixture.defaults() }
    func testDefaultsAndCompoundRulesRoundTripWithoutLosingOrder() throws {
        let original = try defaults()
        XCTAssertNil(original.validation)
        XCTAssertEqual(original.ruleset.rules[2].when.map(\.metric), [.hrRatio, .hrv, .movement])
        XCTAssertEqual(original, try JSONDecoder().decode(RemoteStageClassifier.self, from: JSONEncoder().encode(original)))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(original), as: UTF8.self).contains("\"id\""))
        XCTAssertNotEqual(original.ruleset.rules[0].id, original.ruleset.rules[1].id)
        XCTAssertEqual(original.ruleset.quickCondition(stage: .wake, metric: .movement)?.rule, 0)
    }
    func testInvalidThresholdsRangesAndContractLimitsRejectSave() throws {
        var value = try defaults(); value.ruleset.rules[0].when[0].value = .nan; XCTAssertNotNil(value.validation)
        value = try defaults(); value.ruleset.outliers.heartRate.min = 200; XCTAssertNotNil(value.validation)
        value = try defaults(); value.ruleset.lowSignalBelow = 1.01; XCTAssertNotNil(value.validation)
        value = try defaults(); value.ruleset.outliers.heartRateSpikeStdDevs = -1; XCTAssertNotNil(value.validation)
        value = try defaults(); value.ruleset.rules = Array(repeating: value.ruleset.rules[0], count: 33); XCTAssertNotNil(value.validation)
        value = try defaults(); value.ruleset.rules[0].when = []; XCTAssertNil(value.validation)
        XCTAssertTrue(value.ruleset.rules[0].summary.contains("always"))
    }
    func testPreviewMustMatchBothDraftAndNightWindow() async throws {
        let client = StageMemoryClient(defaults: try defaults()); let model = RemoteStageWorkspace(side: .left, client: client)
        await model.load(); model.draft?.ruleset.lowSignalBelow = 0.4
        XCTAssertFalse(model.canSave); await model.updatePreview(); XCTAssertTrue(model.canSave)
        model.nights = 7; XCTAssertFalse(model.canSave); XCTAssertFalse(model.previewIsCurrent)
        await model.updatePreview(); XCTAssertTrue(model.canSave)
        model.draft?.ruleset.lowSignalBelow = 0.5; XCTAssertFalse(model.canSave)
    }
    func testConflictKeepsDraftAndDoesNotWrite() async throws {
        let client = StageMemoryClient(defaults: try defaults()); let model = RemoteStageWorkspace(side: .left, client: client)
        await model.load(); model.draft?.ruleset.lowSignalBelow = 0.4
        let draft = model.draft
        await client.changeExternally()
        let saved = await model.save(draft)
        XCTAssertFalse(saved); XCTAssertEqual(model.draft, draft); XCTAssertTrue(model.error?.contains("another device") == true)
        let writes = await client.writeCount; XCTAssertEqual(writes, 0)
    }
    func testSavedPendingRulesWaitForAcknowledgement() async throws {
        let client = StageMemoryClient(defaults: try defaults()); let model = RemoteStageWorkspace(side: .left, client: client)
        await model.load(); model.draft?.ruleset.lowSignalBelow = 0.4
        let saved = await model.save(model.draft)
        XCTAssertTrue(saved); XCTAssertNotNil(model.state?.pending); XCTAssertFalse(model.dirty)
        XCTAssertTrue(model.notice?.contains("Waiting") == true)
        await client.acknowledge(); await model.refreshAcknowledgement()
        XCTAssertNil(model.state?.pending); XCTAssertEqual(model.state?.classifier.ruleset.lowSignalBelow, 0.4)
    }
    func testFailedSideLoadDoesNotKeepOtherSleepersRules() async throws {
        let client = StageMemoryClient(defaults: try defaults()); let model = RemoteStageWorkspace(side: .left, client: client)
        await model.load(); await model.updatePreview(); await model.load(side: .right)
        XCTAssertEqual(model.side, .right); XCTAssertNil(model.state); XCTAssertNil(model.draft); XCTAssertNil(model.preview)
        XCTAssertNotNil(model.error); XCTAssertFalse(model.canSave)
    }
    func testAcknowledgementRefreshDoesNotOverwriteAnUnsavedDraft() async throws {
        let client = StageMemoryClient(defaults: try defaults()); let model = RemoteStageWorkspace(side: .left, client: client)
        await model.load(); model.draft?.ruleset.lowSignalBelow = 0.4; _ = await model.save(model.draft)
        model.draft?.ruleset.lowSignalBelow = 0.5; await client.acknowledge(); await model.refreshAcknowledgement()
        XCTAssertEqual(model.draft?.ruleset.lowSignalBelow, 0.5); XCTAssertTrue(model.dirty)
    }
    func testResetSendsExplicitNullAndPreviewPreservesServerUnits() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StageContractProtocol.self]
        let transport = CoreRESTClient(endpoint: URL(string: "https://stage-contract.invalid")!, session: URLSession(configuration: configuration))
        let client = CoreRemoteStageClient(transport: transport)
        let state = try await client.state(side: .right); XCTAssertEqual(state.defaults, try defaults())
        try await client.save(side: .right, classifier: nil)
        let preview = try await client.preview(side: .right, classifier: try defaults(), nights: 7)
        XCTAssertEqual(preview.candidate?.distribution["light"], 75)
        XCTAssertEqual(preview.candidate?.durations["deep"], 3600000)
        XCTAssertEqual(preview.candidate?.agreement?.accuracy, 0.81)
        XCTAssertEqual(preview.changed?.changed, 4)
    }
}

private enum StageFixture {
    static func defaults() throws -> RemoteStageClassifier {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Integration/Fixtures/stage-rules-defaults.json")
        return try JSONDecoder().decode(RemoteStageClassifier.self, from: Data(contentsOf: path))
    }
}
private actor StageMemoryClient: RemoteStageClient {
    private let defaults: RemoteStageClassifier
    private var current: RemoteStageState
    var writeCount = 0
    init(defaults: RemoteStageClassifier) {
        self.defaults = defaults
        current = .init(classifier: defaults, isDefault: true, defaults: defaults, presets: [], changes: [])
    }
    func state(side: Side) throws -> RemoteStageState {
        if side == .right { throw APIError.serverError(message: "Side unavailable") }
        return current
    }
    func save(side: Side, classifier: RemoteStageClassifier?) {
        writeCount += 1; current.pending = .init(classifier: classifier ?? defaults, generation: 1, warning: nil)
    }
    func preview(side: Side, classifier: RemoteStageClassifier, nights: Int) -> RemoteStagePreview {
        .init(nights: 0, hasReference: false, saved: nil, candidate: nil, changed: nil, enteredBedAt: nil, leftBedAt: nil)
    }
    func changeExternally() { current.classifier.ruleset.lowSignalBelow = 0.7 }
    func acknowledge() { if let pending = current.pending { current.classifier = pending.classifier; current.pending = nil } }
}
private final class StageContractProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stage-contract.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let rules = try JSONSerialization.jsonObject(with: JSONEncoder().encode(StageFixture.defaults()))
            var response: [String: Any] = ["classifier": rules, "isDefault": true, "defaults": rules, "presets": [], "changes": []]
            if request.httpMethod != "GET" {
                var bytes = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(buffer, count: count) }
                }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                XCTAssertEqual(body["side"] as? String, "right")
                if request.httpMethod == "PUT" { XCTAssertTrue(body["classifier"] is NSNull) }
                else {
                    XCTAssertEqual(request.url?.path, "/api/sleep-stages/classifier/preview"); XCTAssertEqual(body["nights"] as? Int, 7)
                    let summary: [String: Any] = ["distribution": ["light": 75, "deep": 25], "durations": ["light": 10800000, "deep": 3600000], "qualityScore": 82, "agreement": ["accuracy": 0.81, "kappa": 0.62]]
                    response = ["nights": 7, "hasReference": true, "candidate": summary, "saved": summary, "changed": ["changed": 4, "total": 96, "segments": []]]
                }
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: response)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
