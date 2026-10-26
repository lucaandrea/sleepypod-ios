import XCTest
@testable import Sleepypod

@MainActor final class RemoteStageModelAlignmentTests: XCTestCase {
    private func fixture() throws -> JSONValue {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Integration/Fixtures/stage-model-core-identity.json")
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }
    private func decode<Value: Decodable>(_ value: JSONValue?, as: Value.Type) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(XCTUnwrap(value)))
    }
    func testLiteralCoreIdentityAndActualFallbackAreSeparateFromSelection() throws {
        let source = try fixture()
        let selection = try decode(source["selection"], as: RemoteStageModelSelection.self)
        let library = try decode(source["library"], as: [RemoteStageModelItem].self)
        let active = try decode(source["active"], as: PodSleepStages.self)
        let rules = try decode(source["rules"], as: PodSleepStages.self)
        let fallback = try decode(source["noEpochs"], as: PodSleepStages.self)
        let expected = "8a5032bd96d24ea97d5c122da89e804d6c7a72be757c87829974a185d3b5d54e"
        XCTAssertEqual(selection.modelHash, expected); XCTAssertEqual(library.first?.modelHash, expected)
        XCTAssertEqual(active.stagedBy?.modelHash, expected); XCTAssertEqual(active.stagedBy?.reason, "active_model")
        XCTAssertFalse(active.blocks.isEmpty); XCTAssertNil(active.stagedBy?.fallbackExplanation)
        XCTAssertEqual(rules.sourceLabel, "Pod rules"); XCTAssertNil(rules.stagedBy?.modelHash)
        XCTAssertEqual(fallback.stagedBy?.reason, "no_model_epochs"); XCTAssertNotNil(fallback.stagedBy?.fallbackExplanation)
        XCTAssertEqual(fallback.sourceLabel, "Pod rules"); XCTAssertNil(fallback.stagedBy?.modelHash)
        let failed = PodSleepStages.StagedBy(engine: "rules", version: nil, reason: "model_evaluation_failed")
        XCTAssertTrue(failed.fallbackExplanation?.contains("failed") == true)
    }
    func testCoreByteBudgetAndFileReadRejectOversizeWithoutLosingMetadata() throws {
        let source = try fixture()
        XCTAssertEqual(RemoteStageModelDocument.maximumBytes, Int(source["maximumBytes"]!.number!))
        var bytes = try JSONEncoder().encode(XCTUnwrap(source["model"]))
        bytes.append(Data(repeating: 32, count: RemoteStageModelDocument.maximumBytes - bytes.count))
        let accepted = try RemoteStageModelDocument.read(bytes)
        XCTAssertEqual(accepted.metrics?["demo"]?.string, "Synthetic scores for interface demonstration only")
        bytes.append(32)
        XCTAssertThrowsError(try RemoteStageModelDocument.read(bytes))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try bytes.write(to: url)
        XCTAssertThrowsError(try RemoteStageModelDocument.readFile(url))
    }
    func testInactiveCandidatePreviewUsesChosenIdentifierAndRulesChoiceClearsIt() async throws {
        let client = try memory(); let workspace = RemoteStageModelWorkspace(side: .left, client: client)
        await workspace.load(); XCTAssertEqual(workspace.choice, 1)
        workspace.choice = 2; XCTAssertEqual(workspace.previewTitle, "Candidate B")
        await workspace.previewModel()
        let requested = await client.requestedID; let writes = await client.writes
        XCTAssertEqual(requested, 2); XCTAssertEqual(writes, 0)
        XCTAssertEqual(workspace.preview?.version, "Candidate B")
        workspace.choice = nil; XCTAssertNil(workspace.preview); XCTAssertFalse(workspace.canPreview)
        workspace.choice = 2; await workspace.previewModel(); workspace.nights = 30
        XCTAssertNil(workspace.preview)
    }
    func testChangedChoiceRejectsLateCandidatePreview() async throws {
        let client = try memory(); await client.configure(hold: true)
        let workspace = RemoteStageModelWorkspace(side: .left, client: client)
        await workspace.load(); workspace.choice = 2
        let pending = Task { await workspace.previewModel() }
        await client.waitUntilPreviewHeld(); workspace.choice = 1
        await client.release(); await pending.value
        XCTAssertNil(workspace.preview); XCTAssertFalse(workspace.previewing)
    }
    func testFailedOrWrongCandidatePreviewStaysVisibleAndCanRetry() async throws {
        let client = try memory(); let workspace = RemoteStageModelWorkspace(side: .left, client: client)
        await workspace.load(); workspace.choice = 2
        await client.configure(wrongVersion: true); await workspace.previewModel()
        XCTAssertNil(workspace.preview); XCTAssertTrue(workspace.error?.contains("different model") == true)
        await client.configure(fail: true); await workspace.previewModel()
        XCTAssertNil(workspace.preview); XCTAssertNotNil(workspace.error); XCTAssertTrue(workspace.canPreview)
        await client.configure(); await workspace.previewModel()
        XCTAssertEqual(workspace.preview?.version, "Candidate B"); XCTAssertNil(workspace.error)
    }
    func testInvalidScoresCannotReachPercentageFormatting() throws {
        let invalid = RemoteStageModelPreview(version: "Candidate", nights: [],
            pooled: .init(epochs: 5, accuracy: 1e300, kappa: 0.4, recall: nil), rulesPooled: nil)
        XCTAssertThrowsError(try invalid.validate(expectedVersion: "Candidate", maximumNights: 7))
        let missing = RemoteStageModelPreview(version: "Candidate", nights: [], pooled: nil, rulesPooled: nil)
        XCTAssertNoThrow(try missing.validate(expectedVersion: "Candidate", maximumNights: 7))
    }
    private func memory() throws -> AlignmentModelClient {
        try AlignmentModelClient(document: decode(fixture()["model"], as: RemoteStageModelDocument.self))
    }
}

private actor AlignmentModelClient: RemoteStageModelClient {
    let document: RemoteStageModelDocument
    private(set) var requestedID: Int?
    private(set) var writes = 0
    private var fail = false
    private var hold = false
    private var wrongVersion = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var ready: CheckedContinuation<Void, Never>?
    init(document: RemoteStageModelDocument) { self.document = document }
    func configure(hold: Bool = false, wrongVersion: Bool = false, fail: Bool = false) {
        self.hold = hold; self.wrongVersion = wrongVersion; self.fail = fail
    }
    func state(side: Side) -> RemoteStageModelState {
        .init(supported: true, previewSupported: true,
              selection: .init(model: document, uploadedAt: 1, active: true, modelHash: "active-hash"),
              library: [1, 2].map { identifier in
                  .init(id: identifier, version: identifier == 1 ? document.version : "Candidate B", kind: "forest", uploadedAt: 1,
                        metrics: nil, selected: identifier == 1, active: identifier == 1, modelHash: "hash-\(identifier)")
              })
    }
    func preview(side: Side, document: RemoteStageModelDocument?, modelId: Int?, nights: Int) async throws -> RemoteStageModelPreview {
        requestedID = modelId
        if hold {
            await withCheckedContinuation { continuation = $0; ready?.resume(); ready = nil }
        }
        if fail { throw APIError.serverError(message: "Read failed") }
        return .init(version: wrongVersion ? "Unrelated" : modelId == 2 ? "Candidate B" : self.document.version,
                     nights: [], pooled: nil, rulesPooled: nil)
    }
    func waitUntilPreviewHeld() async {
        if continuation != nil { return }
        await withCheckedContinuation { ready = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
    func upload(side: Side, document: RemoteStageModelDocument) -> Int { writes += 1; return 3 }
    func select(side: Side, id: Int, active: Bool) { writes += 1 }
    func setActive(side: Side, active: Bool) { writes += 1 }
}
