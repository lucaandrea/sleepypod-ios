import Foundation
import Observation

@MainActor @Observable final class SleepPeriodStageWorkspace {
    private(set) var summaries: [Int: SleepNightStageSummary] = [:]
    private(set) var errors: [Int: String] = [:]
    private(set) var loading = false
    private var revision = 0

    /// Fetch only the seven main sessions. Each response must still belong to this side/window and record.
    func load(records: [SleepRecord], side: Side,
              fetch: @Sendable (Side, Int) async throws -> PodSleepStages) async {
        revision += 1
        let currentRevision = revision
        summaries = [:]; errors = [:]; loading = true
        for record in records.prefix(7) where record.side == side.rawValue {
            do {
                let result = try await fetch(side, record.id)
                guard currentRevision == revision, !Task.isCancelled else { return }
                guard result.sleepRecordId == nil || result.sleepRecordId == record.id else {
                    errors[record.id] = "The Pod returned stages for another night."; continue
                }
                summaries[record.id] = .init(epochs: result.comparisonEpochs, quality: result.score, source: result.sourceLabel)
            } catch {
                guard currentRevision == revision, !Task.isCancelled else { return }
                errors[record.id] = error.localizedDescription
            }
        }
        if currentRevision == revision { loading = false }
    }
}
