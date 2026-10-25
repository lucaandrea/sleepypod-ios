import Foundation

protocol RemoteStageModelClient: Sendable {
    func state(side: Side) async throws -> RemoteStageModelState
    func upload(side: Side, document: RemoteStageModelDocument) async throws -> Int
    func select(side: Side, id: Int, active: Bool) async throws
    func setActive(side: Side, active: Bool) async throws
    func preview(side: Side, document: RemoteStageModelDocument?, nights: Int) async throws -> RemoteStageModelPreview
}
struct CoreRemoteStageModelClient: RemoteStageModelClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient {
        get throws { guard let transport else { throw APIError.noBaseURL }; return transport }
    }
    func state(side: Side) async throws -> RemoteStageModelState {
        let api = try client
        let schema: CoreAPIDocument = try await api.get("openapi.json")
        let required = [("/sleep-stages/models", "get"), ("/sleep-stages/models", "post"), ("/sleep-stages/models/selected", "put"), ("/sleep-stages/model", "get"), ("/sleep-stages/model/active", "put")]
        guard required.allSatisfy({ schema.operation($0.0, method: $0.1) != nil }) else {
            return .init(supported: false, previewSupported: false, selection: nil, library: [])
        }
        async let selection: RemoteStageModelSelection = api.get("sleep-stages/model", query: ["side": side.rawValue])
        async let library: [RemoteStageModelItem] = api.get("sleep-stages/models", query: ["side": side.rawValue])
        return try await .init(supported: true, previewSupported: schema.operation("/sleep-stages/model/preview", method: "post") != nil, selection: selection, library: library)
    }
    func upload(side: Side, document: RemoteStageModelDocument) async throws -> Int {
        struct Request: Encodable, Sendable { let side: Side; let model: RemoteStageModelDocument }
        struct Response: Decodable, Sendable { let id: Int; let version: String }
        let response: Response = try await client.post("sleep-stages/models", body: Request(side: side, model: document), returning: Response.self)
        return response.id
    }
    func select(side: Side, id: Int, active: Bool) async throws {
        struct Request: Encodable, Sendable { let side: Side; let id: Int; let active: Bool }
        struct Response: Decodable, Sendable { let version: String; let active: Bool }
        let _: Response = try await client.put("sleep-stages/models/selected", body: Request(side: side, id: id, active: active), returning: Response.self)
    }
    func setActive(side: Side, active: Bool) async throws {
        struct Request: Encodable, Sendable { let side: Side; let active: Bool }
        struct Response: Decodable, Sendable { let active: Bool }
        let _: Response = try await client.put("sleep-stages/model/active", body: Request(side: side, active: active), returning: Response.self)
    }
    func preview(side: Side, document: RemoteStageModelDocument?, nights: Int) async throws -> RemoteStageModelPreview {
        struct Request: Encodable, Sendable { let side: Side; let model: RemoteStageModelDocument?; let nights: Int }
        return try await client.post("sleep-stages/model/preview", body: Request(side: side, model: document, nights: nights), returning: RemoteStageModelPreview.self)
    }
}
actor DemoRemoteStageModelClient: RemoteStageModelClient {
    private var active: [Side: Bool] = [:]
    private func document() throws -> RemoteStageModelDocument {
        guard let url = Bundle.main.url(forResource: "stage-model-demo", withExtension: "json") else { throw APIError.serverError(message: "Demo model fixture is missing.") }
        return try RemoteStageModelDocument.read(Data(contentsOf: url))
    }
    func state(side: Side) throws -> RemoteStageModelState {
        let document = try document(); let enabled = active[side] ?? false
        return .init(supported: true, previewSupported: true, selection: .init(model: document, uploadedAt: 1792800000000, active: enabled),
                     library: [.init(id: 1, version: document.version, kind: document.kind, uploadedAt: 1792800000000, metrics: document.metrics, selected: true, active: enabled)])
    }
    func upload(side: Side, document: RemoteStageModelDocument) throws -> Int { throw APIError.serverError(message: "Connect to your Pod to upload a model.") }
    func select(side: Side, id: Int, active: Bool) throws {
        guard id == 1 else { throw APIError.serverError(message: "Demo model not found.") }
        self.active[side] = active
    }
    func setActive(side: Side, active: Bool) { self.active[side] = active }
    func preview(side: Side, document: RemoteStageModelDocument?, nights: Int) -> RemoteStageModelPreview {
        .init(version: document?.version, nights: [], pooled: nil, rulesPooled: nil)
    }
}
