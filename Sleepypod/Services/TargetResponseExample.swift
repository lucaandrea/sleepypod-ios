import Foundation

struct TargetResponseExampleFile: Decodable, Sendable {
    let synthetic: Bool
    let sourceCommit: String
    let now: Double
    let status: TargetResponseResearch
    static func load() throws -> Self {
        guard let file = Bundle.main.url(forResource: "target-response-example", withExtension: "json") else { throw TargetResponseResearch.invalid }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard value.synthetic, value.sourceCommit.count == 40 else { throw TargetResponseResearch.invalid }
        return value
    }
}

/// Practice has no transport, personal history or hardware capability.
actor TargetResponseExample: TargetResponseClient {
    private var fitted = false
    private var previews = 0
    private let mode: String
    init(mode: String = "ready") { self.mode = mode }
    func status(side: Side) throws -> TargetResponseResearch {
        if mode == "unavailable" { throw URLError(.notConnectedToInternet) }
        return try Self.value(side: side, mode: mode, fitted: fitted)
    }
    func evaluate(side: Side, datasetHash: String) async throws -> TargetResponseResearch {
        guard datasetHash == String(repeating: "a", count: 64), mode != "empty" else { throw TargetResponseResearch.invalid }
        try await Task.sleep(for: .milliseconds(500))
        fitted = true
        return try status(side: side)
    }
    func preview(side: Side) throws -> TargetResponsePreview {
        guard fitted else { throw TargetResponseResearch.invalid }
        previews += 1
        return Self.previewValue(side: side, available: previews == 1)
    }
    static func value(side: Side = .left, mode: String = "ready", fitted: Bool = false, now: Date = .now) throws -> TargetResponseResearch {
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TargetResponseExampleFile.load().status)) as? [String: Any] ?? [:]
        let stamp = floor(now.timeIntervalSince1970 * 1000)
        value["generatedAt"] = stamp; value["side"] = side.rawValue
        var evidence = value["evidence"] as? [String: Any] ?? [:]
        evidence["generatedAt"] = stamp; evidence["side"] = side.rawValue
        if mode == "empty" {
            value["completeNights"] = 0; value["canTrain"] = false
            for key in ["reviewedNights", "responseNights", "coolingWindows", "warmingWindows"] { evidence[key] = 0 }
            value["reason"] = "Practice · no qualifying response nights. Collection does not change your routine."
        }
        value["evidence"] = evidence
        if fitted || mode == "failed" || mode == "changed" {
            var model = value["model"] as? [String: Any] ?? [:]
            model["side"] = side.rawValue; model["createdAt"] = stamp - 60_000; model["sourceLastAt"] = stamp - 86_400_000
            if mode == "changed" { model["current"] = false }
            if mode == "failed", var horizons = model["horizons"] as? [[String: Any]], var scores = horizons[0]["validation"] as? [String: Any] {
                scores["passes"] = false; horizons[0]["validation"] = scores; model["horizons"] = horizons
            }
            value["model"] = model
        } else { value["model"] = NSNull() }
        return try JSONDecoder().decode(TargetResponseResearch.self, from: JSONSerialization.data(withJSONObject: value))
    }
    static func previewValue(side: Side = .left, available: Bool = true, now: Date = .now) -> TargetResponsePreview {
        .init(apiVersion: 1, side: side, generatedAt: floor(now.timeIntervalSince1970 * 1000), activationAvailable: false,
            reason: available ? "Practice · illustrative water estimates. No command is sent." : "Fresh occupied-bed readings are unavailable.",
            candidates: available ? [
                .init(targetF: 69, reason: "Comparable example conditions", predictions: [15, 30].map {
                    .init(minutes: $0, waterF: 69.4, lowerF: 68.9, upperF: 69.9)
                }),
                .init(targetF: 71, reason: "No comparable warming observations. Keep the current routine.", predictions: [])
            ] : [])
    }
}
