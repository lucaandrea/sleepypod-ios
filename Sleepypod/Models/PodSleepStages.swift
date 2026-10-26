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
    let qualityScore: Double?
    let totalSleepMs: Double?
    let stagedBy: StagedBy?
    let stageView: StageView?
    struct StagedBy: Decodable, Sendable {
        let engine: String
        let version: String?
        let modelHash: String?
        let reason: String?
        init(engine: String, version: String?, modelHash: String? = nil, reason: String? = nil) {
            self.engine = engine; self.version = version; self.modelHash = modelHash; self.reason = reason
        }
        var fallbackExplanation: String? {
            switch reason {
            case "no_model_epochs": "Rules were used because the selected model produced no usable epochs."
            case "model_evaluation_failed": "Rules were used because model evaluation failed."
            default: nil
            }
        }
    }
    struct StageView: Decodable, Sendable { let provenance: RemoteStageState.Provenance }

    init(blocks: [Block], sleepRecordId: Int?, qualityScore: Double? = nil, totalSleepMs: Double? = nil, stagedBy: StagedBy? = nil, stageView: StageView? = nil) {
        self.blocks = blocks; self.sleepRecordId = sleepRecordId; self.qualityScore = qualityScore
        self.totalSleepMs = totalSleepMs; self.stagedBy = stagedBy; self.stageView = stageView
    }
    var score: Int? { qualityScore.flatMap { $0.isFinite && (0...100).contains($0) ? Int($0.rounded()) : nil } }
    var sleepSeconds: Int? { totalSleepMs.flatMap { $0.isFinite && (0...172800000).contains($0) ? Int($0 / 1000) : nil } }
    var sourceLabel: String {
        guard let stagedBy else { return "Pod · source not reported" }
        switch stagedBy.engine {
        case "model": return "Pod model\(stagedBy.version.map { " · " + $0 } ?? "")"
        case "rules": return "Pod rules"
        default: return "Pod · \(stagedBy.engine)"
        }
    }
    /// Stage-only minute slices preserve gaps and the comparison's minute resolution. Vitals are separate.
    var comparisonEpochs: [SleepAnalyzer.SleepEpoch] {
        var result: [SleepAnalyzer.SleepEpoch] = []
        for block in blocks.sorted(by: { $0.start < $1.start }) {
            guard block.start.isFinite, block.end.isFinite, block.end > block.start,
                  block.end - block.start <= 48 * 3600000, let stage = block.sleepStage else { continue }
            var start = block.startDate
            while start < block.endDate && result.count < 10000 {
                let duration = min(60, block.endDate.timeIntervalSince(start))
                result.append(.init(start: start, duration: duration, stage: stage, heartRate: .nan, hrv: nil, breathingRate: nil))
                start = start.addingTimeInterval(duration)
            }
        }
        return result
    }
}
