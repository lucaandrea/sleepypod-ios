import Foundation

/// Core folds each side's recent nights; `nights` is the larger side count, not their sum.
struct AutomationReplaySummary: Decodable, Equatable, Sendable {
    let id: Int?
    let nights: Int
    let wouldFire: Int
    let peak: Double?
    let low: Double?
    let threshold: Double?
    var headline: String {
        nights == 0 ? "No replayable nights returned" : "Would fire \(wouldFire) times across \(nights) recorded night\(nights == 1 ? "" : "s")"
    }
}

struct AutomationRangeRequest: Encodable, Sendable {
    let nights: Int
    let rule: AutomationBacktestRequest.Rule
}
