import Foundation
import Observation

@MainActor @Observable final class SystemDashboardWorkspace {
    private(set) var runtime: SystemRuntimeFacts?
    private(set) var maintenance: SystemMaintenanceFacts?
    private(set) var health: SystemHealthPath?
    private(set) var thermal: SystemThermalSnapshot?
    private(set) var history: SystemThermalHistory?
    private(set) var timeline: SystemSchedulerTimeline?
    private(set) var errors: [String: String] = [:]
    private(set) var receivedAt: [String: Date] = [:]
    private(set) var loading = false
    private var detailsAttemptAt: Date?
    private let client: any SystemDashboardClient
    private let healthClient: any SystemHealthClient
    private let thermalClient: any SystemThermalClient
    private let schedulerClient: any SystemSchedulerClient
    init(client: any SystemDashboardClient, health: any SystemHealthClient, thermal: any SystemThermalClient, scheduler: any SystemSchedulerClient) {
        self.client = client; healthClient = health; thermalClient = thermal; schedulerClient = scheduler
    }
    func fresh(_ section: String, now: Date = .now) -> Bool {
        guard errors[section] == nil, let received = receivedAt[section] else { return false }
        return (0...(section == "Thermal" ? 30 : 90)).contains(now.timeIntervalSince(received))
    }
    // Refresh live delivery frequently; expensive history and diagnostics are read once per minute.
    func refresh(details: Bool = false, now: Date = .now) async {
        guard !loading else { return }
        loading = true
        defer { loading = false; if Task.isCancelled { detailsAttemptAt = nil } }
        let client = client, healthClient = healthClient, thermalClient = thermalClient, schedulerClient = schedulerClient
        async let nextThermal = Self.read { try await thermalClient.snapshot() }
        if details || (detailsAttemptAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true) {
            detailsAttemptAt = now
            async let nextRuntime = Self.read { try await client.runtime() }
            async let nextMaintenance = Self.read { try await client.maintenance() }
            async let nextHealth = Self.read { try await healthClient.path() }
            async let nextHistory = Self.read { try await thermalClient.history(.day) }
            async let nextTimeline = Self.read { try await schedulerClient.timeline() }
            let values = await (nextRuntime, nextMaintenance, nextHealth, nextHistory, nextTimeline)
            guard !Task.isCancelled else { return }
            runtime = accept(values.0, keeping: runtime, section: "Runtime", at: now)
            maintenance = accept(values.1, keeping: maintenance, section: "Maintenance", at: now)
            health = accept(values.2, keeping: health, section: "Health", at: now)
            history = accept(values.3, keeping: history, section: "History", at: now)
            timeline = accept(values.4, keeping: timeline, section: "Tonight", at: now)
        }
        let value = await nextThermal
        guard !Task.isCancelled else { return }
        thermal = accept(value, keeping: thermal, section: "Thermal", at: now)
    }
    private enum Read<Value: Sendable>: Sendable { case value(Value), failure(String) }
    private nonisolated static func read<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async -> Read<Value> {
        do { return .value(try await operation()) } catch { return .failure(error.localizedDescription) }
    }
    private func accept<Value: Sendable>(_ result: Read<Value>, keeping previous: Value?, section: String, at now: Date) -> Value? {
        switch result {
        case .value(let value): errors[section] = nil; receivedAt[section] = now; return value
        case .failure(let message): errors[section] = message; return previous
        }
    }
}
