import Foundation
import Observation

@MainActor @Observable final class BiometricBacktestJobLibrary {
    let side: Side
    let client: any BiometricDatasetsServing
    private(set) var page: BiometricBacktestPage?
    private(set) var cursor: BiometricBacktestPage.Cursor?
    private(set) var loading = false
    private(set) var error: String?
    private var generation = 0
    init(side: Side, client: any BiometricDatasetsServing) { self.side = side; self.client = client }
    func load(_ cursor: BiometricBacktestPage.Cursor? = nil) async {
        generation += 1; let current = generation
        loading = true
        defer { if generation == current { loading = false } }
        do {
            let result = try await client.jobs(side: side, cursor: cursor)
            guard !Task.isCancelled, generation == current else { return }
            guard result.items.count <= 50, Set(result.items.map(\.id)).count == result.items.count, result.items.allSatisfy(\.validIdentity) else {
                throw BiometricBacktestInput.error("The job library returned inconsistent identities or progress.")
            }
            var previous = cursor
            for item in result.items {
                if let previous, !(item.createdAtMs < previous.createdAtMs || (item.createdAtMs == previous.createdAtMs && item.id < previous.id)) { throw BiometricBacktestInput.error("The job page did not advance.") }
                previous = .init(createdAtMs: item.createdAtMs, id: item.id)
            }
            if let next = result.nextCursor, next != previous || result.items.isEmpty { throw BiometricBacktestInput.error("The job page returned an inconsistent cursor.") }
            page = result; self.cursor = cursor; error = nil
        } catch { if !Task.isCancelled, generation == current { self.error = error.localizedDescription } }
    }
}
