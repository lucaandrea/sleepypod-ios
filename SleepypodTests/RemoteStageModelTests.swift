import XCTest
@testable import Sleepypod

@MainActor final class RemoteStageModelTests: XCTestCase {
    private func document() throws -> RemoteStageModelDocument { try ModelFixture.document() }
    private func file() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("candidate.json")
        try JSONEncoder().encode(document()).write(to: file)
        return file
    }
    func testPortableDocumentRetainsClassOrderAndArbitraryMetadata() throws {
        let original = try document()
        let roundTrip = try RemoteStageModelDocument.read(JSONEncoder().encode(original))
        XCTAssertEqual(original, roundTrip)
        XCTAssertEqual(roundTrip.json["classes"]?.strings, ["wake", "light", "deep", "rem"])
        XCTAssertEqual(roundTrip.metrics?["demo"]?.string, "Synthetic scores for interface demonstration only")
    }
    func testWrongClassesEpochOrTestVectorsRejectBeforeUpload() throws {
        let raw = String(decoding: try JSONEncoder().encode(document()), as: UTF8.self)
        XCTAssertThrowsError(try RemoteStageModelDocument.read(Data(raw.replacingOccurrences(of: "\"epochSeconds\":300", with: "\"epochSeconds\":30").utf8)))
        XCTAssertThrowsError(try RemoteStageModelDocument.read(Data(raw.replacingOccurrences(of: "\"expected\":2", with: "\"expected\":1").utf8)))
        guard case .object(var object) = try document().json else { return XCTFail("Expected object") }
        object["classes"] = .array([.string("light"), .string("wake"), .string("deep"), .string("rem")])
        XCTAssertThrowsError(try RemoteStageModelDocument.read(JSONEncoder().encode(StageModelJSON.object(object))))
    }
    func testScorecardUsesHeldOutMetricsAndKeepsMissingScoresMissing() throws {
        let score = RemoteStageModelScore(metrics: try document().metrics)
        XCTAssertEqual(score.kappa, 0.62); XCTAssertEqual(score.baseline, 0.4); XCTAssertEqual(score.nights, 10)
        XCTAssertEqual(score.recall[.rem], 0.64)
        let training = try JSONDecoder().decode(StageModelJSON.self, from: Data(#"{"training":{"kappa":0.99},"lono":{"kappa":2,"nights":-1,"recall":{"deep":1.2}}}"#.utf8))
        let invalid = RemoteStageModelScore(metrics: training)
        XCTAssertNil(invalid.kappa); XCTAssertNil(invalid.nights); XCTAssertNil(invalid.recall[.deep]); XCTAssertNil(invalid.baseline)
    }
    func testPreparedFileIsAnImmutableDocumentAndDoesNotUpload() async throws {
        let file = try file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let client = ModelMemoryClient(document: try document()); let model = RemoteStageModelWorkspace(side: .left, client: client)
        await model.load(); await model.prepare(file)
        try Data("modified".utf8).write(to: file)
        XCTAssertEqual(model.prepared?.version, "Demo forest")
        let writes = await client.uploads; XCTAssertEqual(writes, 0)
        model.discardFile(); XCTAssertNil(model.prepared)
    }
    func testUploadAddsLibraryCandidateWithoutActivation() async throws {
        let file = try file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let client = ModelMemoryClient(document: try document()); let model = RemoteStageModelWorkspace(side: .left, client: client)
        await model.load(); await model.prepare(file); await model.upload()
        let uploads = await client.uploads; let activations = await client.activations
        XCTAssertEqual(uploads, 1); XCTAssertEqual(activations, 0); XCTAssertFalse(model.state?.selection?.active ?? true)
        XCTAssertEqual(model.choice, 2); XCTAssertNil(model.prepared)
    }
    func testSelectionConflictDoesNotOverwriteOtherDevice() async throws {
        let client = ModelMemoryClient(document: try document()); let model = RemoteStageModelWorkspace(side: .left, client: client)
        await model.load(); model.choice = 1
        await client.changeSelection(); await model.apply()
        let activations = await client.activations; XCTAssertEqual(activations, 0)
        XCTAssertTrue(model.error?.contains("another device") == true)
    }
    func testSideSwitchClearsPreparedModelAndFailedSideData() async throws {
        let file = try file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let client = ModelMemoryClient(document: try document()); let model = RemoteStageModelWorkspace(side: .left, client: client)
        await model.load(); await model.prepare(file); await model.load(side: .right)
        XCTAssertNil(model.prepared); XCTAssertNil(model.state); XCTAssertNil(model.choice); XCTAssertNotNil(model.error)
    }
    func testTransportDetectsSupportAndPreservesRawUploadDocument() async throws {
        let client = client()
        let state = try await client.state(side: .right)
        XCTAssertTrue(state.supported); XCTAssertTrue(state.previewSupported); XCTAssertEqual(state.library.first?.id, 1)
        let id = try await client.upload(side: .right, document: document()); XCTAssertEqual(id, 2)
        try await client.select(side: .right, id: 1, active: true)
        try await client.setActive(side: .right, active: false)
        let result = try await client.preview(side: .right, document: document(), modelId: nil, nights: 7)
        XCTAssertTrue(result.nights.isEmpty); XCTAssertNil(result.pooled)
        let chosen = try await client.preview(side: .right, document: nil, modelId: 12, nights: 7)
        XCTAssertEqual(chosen.version, "Chosen candidate")
        do {
            _ = try await client.preview(side: .right, document: document(), modelId: 12, nights: 7)
            XCTFail("Ambiguous preview must not send")
        } catch { }
        do {
            _ = try await client.preview(side: .right, document: nil, modelId: -1, nights: 7)
            XCTFail("Invalid library identity must not send")
        } catch { }
    }
    func testMissingModelRoutesDoNotSendUnsupportedRequests() async throws {
        let state = try await client(host: "model-old.invalid").state(side: .right)
        XCTAssertFalse(state.supported); XCTAssertNil(state.selection); XCTAssertTrue(state.library.isEmpty)
    }
    private func client(host: String = "model-current.invalid") -> CoreRemoteStageModelClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ModelContractProtocol.self]
        return CoreRemoteStageModelClient(transport: .init(endpoint: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration)))
    }
}
private enum ModelFixture {
    static func document() throws -> RemoteStageModelDocument {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Integration/Fixtures/stage-model-demo.json")
        return try RemoteStageModelDocument.read(Data(contentsOf: file))
    }
}
private actor ModelMemoryClient: RemoteStageModelClient {
    let document: RemoteStageModelDocument
    var uploads = 0
    var activations = 0
    private var active = false
    init(document: RemoteStageModelDocument) { self.document = document }
    func state(side: Side) throws -> RemoteStageModelState {
        if side == .right { throw APIError.serverError(message: "Unavailable") }
        return .init(supported: true, previewSupported: true, selection: .init(model: document, uploadedAt: 1, active: active),
                     library: [.init(id: 1, version: document.version, kind: document.kind, uploadedAt: 1, metrics: document.metrics, selected: true, active: active)])
    }
    func upload(side: Side, document: RemoteStageModelDocument) -> Int { uploads += 1; return 2 }
    func select(side: Side, id: Int, active: Bool) { activations += 1; self.active = active }
    func setActive(side: Side, active: Bool) { activations += 1; self.active = active }
    func changeSelection() { active = true }
    func preview(side: Side, document: RemoteStageModelDocument?, modelId: Int?, nights: Int) -> RemoteStageModelPreview { .init(version: document?.version, nights: [], pooled: nil, rulesPooled: nil) }
}
private final class ModelContractProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { ["model-current.invalid", "model-old.invalid"].contains(request.url?.host ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let document = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ModelFixture.document()))
            let url = try XCTUnwrap(request.url)
            var body: [String: Any] = [:]
            if request.httpMethod != "GET" {
                var bytes = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(buffer, count: count) }
                }
                body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any]); XCTAssertEqual(body["side"] as? String, "right")
            }
            let response: Any
            switch (url.path, request.httpMethod) {
            case ("/api/openapi.json", _):
                response = url.host == "model-old.invalid" ? ["paths": [:]] : ["paths": ["/sleep-stages/models": ["get": [:], "post": [:]], "/sleep-stages/models/selected": ["put": [:]], "/sleep-stages/model": ["get": [:]], "/sleep-stages/model/active": ["put": [:]], "/sleep-stages/model/preview": ["post": [:]]]]
            case ("/api/sleep-stages/model", "GET"): response = ["model": document, "uploadedAt": 1, "active": false]
            case ("/api/sleep-stages/models", "GET"): response = [["id": 1, "version": "Demo forest", "kind": "forest", "uploadedAt": 1, "selected": true, "active": false]]
            case ("/api/sleep-stages/models", "POST"):
                let uploaded = try XCTUnwrap(body["model"] as? [String: Any]); XCTAssertEqual(uploaded["classes"] as? [String], ["wake", "light", "deep", "rem"])
                XCTAssertNotNil((uploaded["metrics"] as? [String: Any])?["demo"])
                XCTAssertEqual(Set(body.keys), ["side", "model"]); response = ["id": 2, "version": "Demo forest"]
            case ("/api/sleep-stages/models/selected", "PUT"):
                XCTAssertEqual(body["id"] as? Int, 1); XCTAssertEqual(body["active"] as? Bool, true); response = ["active": true, "version": "Demo forest"]
            case ("/api/sleep-stages/model/active", "PUT"):
                XCTAssertEqual(body["active"] as? Bool, false); response = ["active": false]
            case ("/api/sleep-stages/model/preview", "POST"):
                XCTAssertEqual(body["nights"] as? Int, 7)
                if body["modelId"] != nil {
                    XCTAssertEqual(body["modelId"] as? Int, 12); XCTAssertEqual(Set(body.keys), ["side", "modelId", "nights"])
                    response = ["version": "Chosen candidate", "nights": [], "pooled": NSNull(), "rulesPooled": NSNull()]
                } else {
                    XCTAssertNotNil(body["model"]); XCTAssertEqual(Set(body.keys), ["side", "model", "nights"])
                    response = ["version": "Demo forest", "nights": [], "pooled": NSNull(), "rulesPooled": NSNull()]
                }
            default: XCTFail("Unexpected model request: \(request)"); response = [:]
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: response)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
