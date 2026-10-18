import Foundation

/// The pod's own rule-based stages for one sleep record (sleepypod-core `biometrics.getSleepStages`).
/// Only the merged blocks are kept; the per-epoch vitals the core also returns are fetched separately.
struct PodSleepStages: Decodable, Sendable {
    struct Block: Decodable, Sendable, Equatable {
        /// Unix milliseconds, as the core sends them.
        let start: Double
        let end: Double
        let stage: String

        var startDate: Date { Date(timeIntervalSince1970: start / 1000) }
        var endDate: Date { Date(timeIntervalSince1970: end / 1000) }
        /// The core's lowercase stage names; anything else is dropped rather than guessed.
        var sleepStage: SleepAnalyzer.SleepStage? {
            switch stage {
            case "wake": .wake
            case "light": .light
            case "deep": .deep
            case "rem": .rem
            default: nil
            }
        }
    }

    let blocks: [Block]
    let sleepRecordId: Int?
}
