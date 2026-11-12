import Foundation

protocol TemporaryCoolingClient: Sendable { func read(side: Side) async throws -> TemporaryCooling }
struct CoreTemporaryCoolingClient: TemporaryCoolingClient {
    let transport: CoreRESTClient
    func read(side: Side) async throws -> TemporaryCooling {
        let result: TemporaryCooling = try await transport.get("device/cooling", query: ["side": side.rawValue])
        try result.validate(for: side)
        return result
    }
}
