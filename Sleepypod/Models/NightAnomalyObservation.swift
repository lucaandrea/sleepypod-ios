import CryptoKit
import Foundation

/// One reviewed, complete night from one Health source. Missing readings are never zero-filled.
struct NightAnomalyObservation: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let sourceID: String
    let sourceName: String
    let start: Date
    let end: Date
    let values: [String: Double]
    let coverage: Double
    let maximumGapMinutes: Double
    let sampleCount: Int
    let evidenceDigest: String

    var reviewToken: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
