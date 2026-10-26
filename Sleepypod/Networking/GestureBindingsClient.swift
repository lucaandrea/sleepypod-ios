import Foundation

protocol GestureBindingsClient: Sendable {
    func settings() async throws -> GestureBindingsSnapshot
    func save(_ draft: GestureDraft) async throws
    func remove(side: Side, tap: CoverTap) async throws
}
struct CoreGestureBindingsClient: GestureBindingsClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient { get throws { guard let transport else { throw APIError.noBaseURL }; return transport } }
    func settings() async throws -> GestureBindingsSnapshot { try await client.get("settings") }
    func save(_ draft: GestureDraft) async throws {
        if let issue = draft.issue { throw APIError.serverError(message: issue) }
        struct Input: Encodable, Sendable { let json: [String: SettingsFieldValue] }
        struct Reply: Decodable, Sendable {
            struct Result: Decodable, Sendable {
                struct Data: Decodable, Sendable { let json: GestureBinding }
                let data: Data
            }
            let result: Result
        }
        let _: Reply = try await client.post("trpc/settings.setGesture", body: Input(json: draft.fields), returning: Reply.self)
    }
    func remove(side: Side, tap: CoverTap) async throws { try await client.delete("settings/gesture", query: ["side": side.rawValue, "tapType": tap.rawValue]) }
}
actor DemoGestureBindingsClient: GestureBindingsClient {
    private var value = GestureBindingsSnapshot.demo
    func settings() -> GestureBindingsSnapshot { value }
    func save(_ draft: GestureDraft) { value.gestures.set(draft.binding, side: draft.side, tap: draft.tap) }
    func remove(side: Side, tap: CoverTap) { value.gestures.set(nil, side: side, tap: tap) }
}
