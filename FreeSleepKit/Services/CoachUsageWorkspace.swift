import Foundation
import Observation

@MainActor @Observable
final class CoachUsageWorkspace {
    private(set) var snapshot: CoachUsage?
    var limit = 100
    private var originalLimit = 100
    private var originalRevision = 0
    private var generation = UUID()
    private(set) var busy = false
    private(set) var error: String?
    private(set) var message: String?
    var valid: Bool { (0...1000).contains(limit) }
    var hasDraft: Bool { limit != originalLimit }
    func invalidate() { generation = UUID(); busy = false }
    func reset() {
        guard let snapshot else { return }
        limit = snapshot.monthlyLimit; originalLimit = snapshot.monthlyLimit; originalRevision = snapshot.revision
        error = nil; message = nil
    }
    func load(_ operation: @MainActor () async throws -> CoachUsage) async {
        guard !busy else { return }
        busy = true; error = nil; let current = generation
        defer { if generation == current { busy = false } }
        do {
            let loaded = try await operation()
            guard !Task.isCancelled, generation == current else { return }
            let preserve = hasDraft; snapshot = loaded
            if !preserve { reset() }
        } catch {
            if !Task.isCancelled, generation == current {
                self.error = "Model usage could not be loaded. Check the connection and update the server and gateway if needed."
            }
        }
    }
    // Keep the draft's original revision across refreshes so another device's changes cannot be overwritten silently.
    func save(_ operation: @MainActor (CoachLimitChange) async throws -> CoachUsage) async {
        guard !busy, snapshot != nil, valid, hasDraft else { return }
        let submitted = CoachLimitChange(monthlyLimit: limit, originalRevision: originalRevision)
        let current = generation; busy = true; error = nil; message = nil
        defer { if generation == current { busy = false } }
        do {
            let saved = try await operation(submitted)
            guard !Task.isCancelled, generation == current else { return }
            snapshot = saved; originalLimit = saved.monthlyLimit; originalRevision = saved.revision
            message = "Monthly model limit saved."
        } catch {
            if !Task.isCancelled, generation == current { self.error = error.localizedDescription }
        }
    }
}
