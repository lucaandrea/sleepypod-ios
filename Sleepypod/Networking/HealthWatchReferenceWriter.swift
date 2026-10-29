import Foundation

struct HealthWatchBatch: Encodable, Sendable {
    let side: Side
    let source = "apple_watch"
    var segments: [HealthWatchSnapshot.Stage]?
    var samples: [HealthWatchSnapshot.Sample]?
    var heart: [HealthWatchSnapshot.Heart]?
    var metric: String?
    var count: Int { segments?.count ?? samples?.count ?? heart?.count ?? 0 }
    var path: String { segments != nil ? "reference-stages" : heart != nil ? "reference-vitals" : "reference-samples" }
    enum CodingKeys: String, CodingKey { case side, source, segments, samples, metric }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(side, forKey: .side); try container.encode(source, forKey: .source)
        try container.encodeIfPresent(segments, forKey: .segments)
        if let heart { try container.encode(heart, forKey: .samples) }
        else { try container.encodeIfPresent(samples, forKey: .samples) }
        try container.encodeIfPresent(metric, forKey: .metric)
    }
    static func batches(_ snapshot: HealthWatchSnapshot, side: Side) -> [Self] {
        chunks(snapshot.stages).map { Self(side: side, segments: $0) }
            + chunks(snapshot.heart).map { Self(side: side, heart: $0) }
            + chunks(snapshot.breathing).map { Self(side: side, samples: $0, metric: "breathing_rate") }
            + chunks(snapshot.hrv).map { Self(side: side, samples: $0, metric: "hrv_sdnn") }
    }
    private static func chunks<Value>(_ values: [Value]) -> [[Value]] {
        stride(from: 0, to: values.count, by: 2000).map { Array(values[$0..<min($0 + 2000, values.count)]) }
    }
}

protocol HealthWatchReferenceWriting: Sendable {
    var destination: String { get }
    func write(_ batch: HealthWatchBatch) async throws -> Int
}
struct CoreHealthWatchReferenceWriter: HealthWatchReferenceWriting {
    let transport: CoreRESTClient
    var destination: String { transport.endpoint.absoluteString }
    func write(_ batch: HealthWatchBatch) async throws -> Int {
        struct Receipt: Decodable, Sendable { let written: Int }
        guard (1...2000).contains(batch.count) else { throw APIError.serverError(message: "Invalid Watch reference batch.") }
        let receipt = try await transport.post("biometrics/\(batch.path)", body: batch, returning: Receipt.self)
        guard (0...batch.count).contains(receipt.written) else { throw APIError.serverError(message: "The Pod returned an invalid import receipt. Retry safely.") }
        return receipt.written
    }
}
