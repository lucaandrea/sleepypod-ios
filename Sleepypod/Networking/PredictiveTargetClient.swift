import Foundation

protocol PredictiveTargetClient: Sendable {
    func preview(side: Side) async throws -> PredictiveTargetPreview
}

struct CorePredictiveTargetClient: PredictiveTargetClient {
    let transport: CoreRESTClient
    func preview(side: Side) async throws -> PredictiveTargetPreview {
        try await transport.get("v1/comfort/predictive/preview", query: ["side": side.rawValue])
    }
}

/// The shared Core fixture is illustrative and never contacts a Pod or an AI provider.
struct PredictiveTargetExample: PredictiveTargetClient {
    let unavailable: Bool
    func preview(side: Side) async throws -> PredictiveTargetPreview {
        if unavailable { throw URLError(.notConnectedToInternet) }
        return try Self.value(side: side)
    }
    static func value(side: Side = .left, now: Date = .now) throws -> PredictiveTargetPreview {
        guard let url = Bundle.main.url(forResource: "predictive-target-example", withExtension: "json"),
              let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              envelope["synthetic"] as? Bool == true, let source = envelope["sourceCommit"] as? String, source.count == 40,
              var record = envelope["preview"] as? [String: Any] else { throw TargetResponseResearch.invalid }
        let stamp = floor(now.timeIntervalSince1970 * 1000)
        record["generatedAt"] = stamp; record["expiresAt"] = stamp + 15_000; record["side"] = side.rawValue
        let result = try JSONDecoder().decode(PredictiveTargetPreview.self, from: JSONSerialization.data(withJSONObject: record))
        try result.validate(side: side, now: now)
        return result
    }
}
