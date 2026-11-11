import Foundation

protocol NightExplanationClient: Sendable {
    func read(side: Side, wakeDate: String) async throws -> NightExplanation
}
struct CoreNightExplanationClient: NightExplanationClient {
    let transport: CoreRESTClient
    func read(side: Side, wakeDate: String) async throws -> NightExplanation {
        try await transport.get("v1/device/night-explanation", query: ["side": side.rawValue, "wakeDate": wakeDate])
    }
}
