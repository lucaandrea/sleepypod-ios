import Foundation
import Observation

@MainActor @Observable final class PodStageNightWorkspace {
    private(set) var results: [PodSleepStages] = []
    var result: PodSleepStages? { requestedCount == 1 ? results.first : nil }
    var sourceLabel: String { Array(Set(results.map(\.sourceLabel))).sorted().joined(separator: " · ") }
    private(set) var epochs: [SleepAnalyzer.SleepEpoch] = []
    private(set) var loading = false
    private(set) var error: String?
    private var revision = 0
    private var requestedCount = 0
    func load(recordID: Int?, side: Side, fetch: @Sendable (Side, Int) async throws -> PodSleepStages) async {
        await load(requests: recordID.map { [($0, nil)] } ?? [], side: side, fetch: fetch)
    }
    func load(records: [SleepRecord], side: Side, fetch: @Sendable (Side, Int) async throws -> PodSleepStages) async {
        let unique = Dictionary(grouping: records.filter { $0.side == side.rawValue }, by: \.id)
        let requests = unique.values.compactMap { $0.first }.sorted { $0.enteredBedDate < $1.enteredBedDate }
            .map { ($0.id, Optional(NightRecordingSummary(records: [$0]).intervals)) }
        await load(requests: requests, side: side, fetch: fetch)
    }
    private func load(requests: [(Int, [DateInterval]?)], side: Side,
                      fetch: @Sendable (Side, Int) async throws -> PodSleepStages) async {
        revision += 1; let request = revision
        results = []; epochs = []; error = nil; loading = false; requestedCount = requests.count
        guard !requests.isEmpty else { return }
        loading = true
        defer { if revision == request { loading = false } }
        var collected: [SleepAnalyzer.SleepEpoch] = [], windows: [DateInterval] = []
        for (recordID, intervals) in requests {
            do {
                let value = try await fetch(side, recordID)
                guard revision == request, !Task.isCancelled else { return }
                guard value.sleepRecordId == recordID else { throw APIError.serverError(message: "The controller returned stages for a different sleep record. Reload this night.") }
                results.append(value)
                if let intervals {
                    windows += intervals
                    collected += NightStageCoverage.epochs(value.comparisonEpochs, within: intervals)
                } else { collected += value.comparisonEpochs }
            } catch {
                guard revision == request, !Task.isCancelled else { return }
                self.error = "Some recording segments could not be classified: " + error.localizedDescription
            }
        }
        epochs = windows.isEmpty ? collected : NightStageCoverage.epochs(collected, within: windows)
    }
}
