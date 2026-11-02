import Foundation

struct StageTrainingExclusion: Sendable, Identifiable {
    let date: Date
    let recordIDs: [Int]
    let reason: String
    var id: String { recordIDs.map(String.init).joined(separator: ",") + ":" + reason }
}
