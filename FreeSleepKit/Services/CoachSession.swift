import Foundation
import Observation

@MainActor @Observable
final class CoachSession {
    private(set) var result: Coaching?
    private(set) var error: String?
    private(set) var busy = false
    private var generation = UUID()
    func invalidate() { generation = UUID(); result = nil; error = nil; busy = false }
    // Only the active snapshot may publish a result; cancelled or superseded replies are discarded.
    func run(_ operation: @MainActor () async throws -> Coaching) async {
        guard !busy else { return }
        let current = UUID(); generation = current; busy = true; result = nil; error = nil
        defer { if current == generation { busy = false } }
        do {
            let response = try await operation()
            guard !Task.isCancelled, current == generation else { return }
            result = response
        } catch {
            guard !Task.isCancelled, current == generation else { return }
            self.error = error.localizedDescription
        }
    }
}
