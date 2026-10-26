import Foundation
import Observation

@MainActor @Observable final class BiometricExperimentLibrary {
    let side: Side
    let client: any BiometricExperimentsServing
    private(set) var page: BiometricExperimentPage?
    private(set) var cursor: BiometricExperimentPage.Cursor?
    private(set) var loading = false
    private(set) var error: String?
    private var generation = 0
    init(side: Side, client: any BiometricExperimentsServing) { self.side = side; self.client = client }
    /// New reads supersede old pages, including a cancelled page from a previous screen visit.
    func load(_ cursor: BiometricExperimentPage.Cursor? = nil) async {
        generation += 1; let current = generation
        loading = true; error = nil
        defer { if generation == current { loading = false } }
        do {
            let result = try await client.experiments(side: side, cursor: cursor)
            guard !Task.isCancelled, generation == current else { return }
            guard result.items.count <= 50, Set(result.items.map(\.id)).count == result.items.count,
                  result.items.allSatisfy({ $0.side == side && $0.validIdentity }) else {
                throw BiometricBacktestInput.error("The experiment library returned unexpected identities. Reload before continuing.")
            }
            var previous = cursor
            for item in result.items {
                if let previous, !(item.createdAtMs < previous.createdAtMs || (item.createdAtMs == previous.createdAtMs && item.id < previous.id)) {
                    throw BiometricBacktestInput.error("The experiment page did not advance. Reload the newest experiments.")
                }
                previous = .init(createdAtMs: item.createdAtMs, id: item.id)
            }
            if let next = result.nextCursor, next != previous || result.items.isEmpty {
                throw BiometricBacktestInput.error("The experiment page returned an inconsistent cursor.")
            }
            page = result; self.cursor = cursor
        } catch { if !Task.isCancelled, generation == current { self.error = error.localizedDescription } }
    }
}
