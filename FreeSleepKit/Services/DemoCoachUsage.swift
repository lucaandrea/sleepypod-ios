import Foundation
import Observation

@MainActor @Observable
final class DemoCoachUsage {
    private(set) var snapshot: CoachUsage?
    private var durations: [String: [Int]] = [:]
    init() {
        struct Attempt: Decodable { var provider: String; var elapsedMilliseconds: Int? }
        struct Fixture: Decodable { var snapshot: CoachUsage; var attempts: [Attempt] }
        if let url = Bundle.main.url(forResource: "usage-demo", withExtension: "json"), let data = try? Data(contentsOf: url) {
            if let fixture = try? JSONDecoder().decode(Fixture.self, from: data) {
                snapshot = fixture.snapshot
                for attempt in fixture.attempts {
                    if let duration = attempt.elapsedMilliseconds { durations[attempt.provider, default: []].append(duration) }
                }
            }
        }
    }
    func read() throws -> CoachUsage {
        guard let snapshot else { throw PodError.message("The sample usage could not be loaded.") }; return snapshot
    }
    func save(_ change: CoachLimitChange) throws -> CoachUsage {
        var current = try read()
        guard (0...1000).contains(change.monthlyLimit) else { throw PodError.message("Choose a whole-number limit from 0 to 1000.") }
        guard current.revision == change.originalRevision else {
            throw PodError.message("The model limit changed elsewhere. Refresh usage and reset your draft.")
        }
        current.monthlyLimit = change.monthlyLimit; current.revision += 1
        current.remaining = max(0, current.monthlyLimit - current.attempts); snapshot = current; return current
    }
    // Demo requests only change synthetic counters in memory, never a saved Pod or provider account.
    func record() throws {
        var current = try read()
        guard current.remaining > 0 else {
            throw PodError.message("The monthly model request limit has been reached. Use local calculations or update the limit in Model usage.")
        }
        durations["openai", default: []].append(1000)
        let allDurations = durations.values.flatMap { $0 }
        current.attempts += 1; current.completed += 1; current.remaining -= 1
        current.averageResponseMilliseconds = Int((Double(allDurations.reduce(0, +)) / Double(allDurations.count)).rounded())
        if let index = current.providers.firstIndex(where: { $0.provider == "openai" }) {
            var provider = current.providers[index]
            let readings = durations["openai"] ?? []
            provider.attempts += 1; provider.completed += 1
            provider.averageResponseMilliseconds = Int((Double(readings.reduce(0, +)) / Double(readings.count)).rounded())
            current.providers[index] = provider
        }
        snapshot = current
    }
}
