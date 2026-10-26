import Foundation
import Observation

@MainActor @Observable
final class SystemSchedulerWorkspace {
    private(set) var timeline: SystemSchedulerTimeline?
    private(set) var health: SystemSchedulerHealth?
    private(set) var loading = false
    private(set) var error: String?
    private(set) var healthError: String?
    private let client: any SystemSchedulerClient
    private var revision = 0
    init(client: any SystemSchedulerClient) { self.client = client }

    // Keep timeline inspection available when the separate system-health request fails.
    func load() async {
        revision += 1; let requested = revision
        loading = true; error = nil; healthError = nil; health = nil
        defer { if revision == requested { loading = false } }
        async let healthResult = readHealth()
        do {
            let result = try await client.timeline()
            guard !Task.isCancelled, revision == requested else { return }
            timeline = result
        } catch {
            if !Task.isCancelled, revision == requested { self.error = error.localizedDescription }
        }
        let result = await healthResult
        guard !Task.isCancelled, revision == requested else { return }
        health = result.value; healthError = result.error
    }
    private func readHealth() async -> (value: SystemSchedulerHealth?, error: String?) {
        do { return (try await client.health(), nil) }
        catch { return (nil, error.localizedDescription) }
    }
}
