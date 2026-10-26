import Foundation

/// Existing portable stage-model APIs share the general JSON transport value.
typealias StageModelJSON = JSONValue

struct RemoteStageModelDocument: Codable, Equatable, Sendable {
    let json: StageModelJSON
    init(from decoder: Decoder) throws { json = try StageModelJSON(from: decoder) }
    func encode(to encoder: Encoder) throws { try json.encode(to: encoder) }
    init(json: StageModelJSON) { self.json = json }
    var version: String { json["version"]?.string ?? "Unknown version" }
    var kind: String { json["kind"]?.string ?? "unknown" }
    var metrics: StageModelJSON? { json["metrics"] }
    static let maximumBytes = 10 * 1024 * 1024

    /// Validate the evaluator contract locally; the controller independently validates the exact upload.
    static func read(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else { throw APIError.serverError(message: "Choose a model JSON file of at most 10 MB.") }
        let document = try JSONDecoder().decode(Self.self, from: data)
        guard case .object(var fields) = document.json,
              let version = fields["version"]?.string, !version.isEmpty, version.count <= 120,
              fields["classes"] == .array(["wake", "light", "deep", "rem"].map(StageModelJSON.string)),
              fields["epochSeconds"] == nil || fields["epochSeconds"]?.number == 300,
              (fields["source"]?.string?.count ?? 0) <= 200 else {
            throw APIError.serverError(message: "This is not a supported five-minute sleep-stage model.")
        }
        // Metadata may contain arbitrary scorecard fields. Keep it in the upload, outside the local evaluator.
        fields.removeValue(forKey: "metrics")
        let model = try JSONDecoder().decode(PortableStageModel.self, from: JSONEncoder().encode(StageModelJSON.object(fields)))
        guard model.testVectors.count <= 64, (model.trees?.count ?? 0) <= 1000 else {
            throw APIError.serverError(message: "This model exceeds the supported tree or test-vector limit.")
        }
        for tree in model.trees ?? [] {
            guard tree.f.allSatisfy({ $0 >= -1 }), tree.l.allSatisfy({ $0 >= -1 }), tree.r.allSatisfy({ $0 >= -1 }),
                  tree.v.joined().allSatisfy({ $0.isFinite && $0 >= 0 }), tree.t.allSatisfy(\.isFinite) else {
                throw APIError.serverError(message: "The model has invalid tree values.")
            }
        }
        if let logistic = model.logistic, !(2...4).contains(logistic.classIndices.count) {
            throw APIError.serverError(message: "The model must classify between two and four stages.")
        }
        try model.validate()
        return document
    }
    static func readFile(_ url: URL) throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard url.pathExtension.lowercased() == "json", values.isRegularFile == true, (values.fileSize ?? 0) <= maximumBytes else {
            throw APIError.serverError(message: "Choose a model JSON file of at most 10 MB.")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        return try read(handle.read(upToCount: maximumBytes + 1) ?? Data())
    }
}
struct RemoteStageModelItem: Decodable, Identifiable, Sendable, Equatable {
    let id: Int
    let version: String
    let kind: String
    let uploadedAt: Double
    let metrics: StageModelJSON?
    let selected: Bool
    let active: Bool
}
struct RemoteStageModelSelection: Decodable, Sendable, Equatable {
    let model: RemoteStageModelDocument?
    let uploadedAt: Double?
    let active: Bool
}
struct RemoteStageModelState: Sendable {
    let supported: Bool
    let previewSupported: Bool
    let selection: RemoteStageModelSelection?
    let library: [RemoteStageModelItem]
}
struct RemoteStageModelScore: Sendable {
    let kappa: Double?
    let baseline: Double?
    let nights: Int?
    let recall: [RemoteSleepStage: Double]
    init(metrics: StageModelJSON?) {
        let evaluation = metrics?["nestedSelection"] ?? metrics?["lono"]
        func valid(_ value: Double?, in range: ClosedRange<Double>) -> Double? { value.flatMap { range.contains($0) ? $0 : nil } }
        kappa = valid(evaluation?["kappa"]?.number, in: -1...1)
        baseline = valid(metrics?["rules"]?["kappa"]?.number, in: -1...1)
        nights = evaluation?["nights"]?.number.flatMap { $0 >= 0 && $0 <= 100000 && $0.rounded() == $0 ? Int($0) : nil }
        recall = Dictionary(uniqueKeysWithValues: RemoteSleepStage.allCases.compactMap { stage in
            valid(evaluation?["recall"]?[stage.rawValue]?.number, in: 0...1).map { (stage, $0) }
        })
    }
}
struct RemoteStageModelPreview: Decodable, Sendable {
    struct Agreement: Decodable, Sendable {
        let epochs: Int
        let accuracy: Double
        let kappa: Double?
        let recall: [String: Double?]?
    }
    struct Night: Decodable, Identifiable, Sendable {
        let sleepRecordId: Int
        let enteredBedAt: Double
        let leftBedAt: Double
        let blocks: [PodSleepStages.Block]
        let agreement: Agreement?
        let rulesAgreement: Agreement?
        var id: Int { sleepRecordId }
    }
    let version: String?
    let nights: [Night]
    let pooled: Agreement?
    let rulesPooled: Agreement?
}
