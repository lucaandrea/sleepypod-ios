import Foundation

/// Captures the exact nights shown for confirmation so a refresh cannot review different records.
struct NightAnomalyReviewBatch: Identifiable {
    let id = UUID()
    let scope: String
    let sourceID: String
    let sourceName: String
    let nights: [NightAnomalyObservation]

    var firstBedtime: Date { nights.map(\.start).min() ?? .distantPast }
    var lastWake: Date { nights.map(\.end).max() ?? .distantPast }
}
