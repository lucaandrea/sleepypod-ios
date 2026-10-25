import Foundation

protocol RemoteStageClient: Sendable {
    func state(side: Side) async throws -> RemoteStageState
    func save(side: Side, classifier: RemoteStageClassifier?) async throws
    func preview(side: Side, classifier: RemoteStageClassifier, nights: Int) async throws -> RemoteStagePreview
}
struct CoreRemoteStageClient: RemoteStageClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient {
        get throws { guard let transport else { throw APIError.noBaseURL }; return transport }
    }
    func state(side: Side) async throws -> RemoteStageState { try await client.get("sleep-stages/classifier", query: ["side": side.rawValue]) }
    func save(side: Side, classifier: RemoteStageClassifier?) async throws {
        struct Request: Encodable, Sendable {
            let side: String
            let classifier: RemoteStageClassifier?
            enum CodingKeys: CodingKey { case side, classifier }
            func encode(to encoder: Encoder) throws {
                var fields = encoder.container(keyedBy: CodingKeys.self)
                try fields.encode(side, forKey: .side)
                if let classifier { try fields.encode(classifier, forKey: .classifier) } else { try fields.encodeNil(forKey: .classifier) }
            }
        }
        struct Response: Decodable, Sendable { let classifier: RemoteStageClassifier; let isDefault: Bool }
        let _: Response = try await client.put("sleep-stages/classifier", body: Request(side: side.rawValue, classifier: classifier), returning: Response.self)
    }
    func preview(side: Side, classifier: RemoteStageClassifier, nights: Int) async throws -> RemoteStagePreview {
        struct Request: Encodable, Sendable { let side: String; let classifier: RemoteStageClassifier; let nights: Int }
        return try await client.post("sleep-stages/classifier/preview", body: Request(side: side.rawValue, classifier: classifier, nights: nights), returning: RemoteStagePreview.self)
    }
}

actor DemoRemoteStageClient: RemoteStageClient {
    private var saved: [Side: RemoteStageClassifier] = [:]
    private var changes: [Side: [RemoteStageState.Change]] = [:]
    private func defaults() throws -> RemoteStageClassifier {
        guard let url = Bundle.main.url(forResource: "stage-rules-defaults", withExtension: "json") else {
            throw APIError.serverError(message: "The demo rules fixture is missing.")
        }
        return try JSONDecoder().decode(RemoteStageClassifier.self, from: Data(contentsOf: url))
    }
    func state(side: Side) throws -> RemoteStageState {
        let defaults = try defaults()
        var movement = defaults; movement.ruleset.rules = defaults.ruleset.lowSignalRules; movement.ruleset.lowSignalBelow = 0
        var hrv = defaults
        hrv.ruleset.rules = [.init(stage: .wake, when: [.init(metric: .movement, op: .greater, value: 200)]),
                            .init(stage: .wake, when: [.init(metric: .hrv, op: .greater, value: 55)]),
                            .init(stage: .deep, when: [.init(metric: .hrv, op: .less, value: 28)]),
                            .init(stage: .rem, when: [.init(metric: .hrv, op: .greater, value: 38)])]
        return RemoteStageState(classifier: saved[side] ?? defaults, isDefault: saved[side] == nil,
            provenance: .init(source: "demo", generation: nil, warning: nil, stageHash: nil), defaults: defaults,
            presets: [.init(id: "default", label: "Default", description: "Heart rate, HRV and movement", classifier: defaults),
                      .init(id: "movementOnly", label: "Movement only", description: "Wake or light from movement", classifier: movement),
                      .init(id: "hrvFirst", label: "HRV first", description: "HRV thresholds with movement wake detection", classifier: hrv)], changes: changes[side] ?? [])
    }
    func save(side: Side, classifier: RemoteStageClassifier?) throws {
        if let validation = classifier?.validation { throw APIError.serverError(message: validation) }
        let before = saved[side]
        saved[side] = classifier
        changes[side, default: []].insert(.init(id: (changes[side]?.count ?? 0) + 1, changedAt: Date.now.timeIntervalSince1970 * 1000,
            summary: classifier == nil ? "Reset to default" : "Updated stage rules", before: before, agreementBefore: nil, agreementAfter: nil), at: 0)
    }
    func preview(side: Side, classifier: RemoteStageClassifier, nights: Int) throws -> RemoteStagePreview {
        if let validation = classifier.validation { throw APIError.serverError(message: validation) }
        // Demo edits are real in-memory drafts; there is no live processor or reference-night result to imply validation.
        return RemoteStagePreview(nights: 0, hasReference: false, saved: nil, candidate: nil, changed: nil, enteredBedAt: nil, leftBedAt: nil)
    }
}
