import Foundation
import Observation

@Observable @MainActor final class TemperatureHistoryWorkspace {
    private(set) var result: TemperatureHistoryResult?
    private(set) var observedAt: Date?
    private(set) var loading = false
    private var generation = 0
    func reset() { generation += 1; result = nil; observedAt = nil; loading = false }
    func load(client: any TemperatureHistoryClient, range: ClosedRange<Date>, now: Date = .now) async {
        generation += 1; let request = generation
        loading = true
        defer { if generation == request { loading = false } }
        // Include entries before the plotted window, so an overlapping sleep session is not discarded.
        let response = await client.load(from: range.lowerBound.addingTimeInterval(-12 * 3600), to: min(range.upperBound, now))
        guard request == generation, !Task.isCancelled else { return }
        result = response; observedAt = now
    }
}
