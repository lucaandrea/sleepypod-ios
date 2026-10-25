import Foundation
import Observation

@MainActor @Observable final class PodStageNightWorkspace {
    private(set) var result: PodSleepStages?
    private(set) var epochs: [SleepAnalyzer.SleepEpoch] = []
    private(set) var loading = false
    private(set) var error: String?
    private var revision = 0
    func load(recordID: Int?, side: Side, fetch: @Sendable (Side, Int) async throws -> PodSleepStages) async {
        revision += 1; let request = revision
        result = nil; epochs = []; error = nil; loading = false
        guard let recordID else { return }
        loading = true
        defer { if revision == request { loading = false } }
        do {
            let value = try await fetch(side, recordID)
            guard revision == request, !Task.isCancelled else { return }
            guard value.sleepRecordId == recordID else { throw APIError.serverError(message: "The controller returned stages for a different sleep record. Reload this night.") }
            result = value; epochs = value.comparisonEpochs
        } catch { if revision == request, !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
