import Foundation

protocol SystemSchedulerClient: Sendable {
    func timeline() async throws -> SystemSchedulerTimeline
    func health() async throws -> SystemSchedulerHealth
}

struct CoreSystemSchedulerClient: SystemSchedulerClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient {
        get throws { guard let transport else { throw APIError.noBaseURL }; return transport }
    }
    func timeline() async throws -> SystemSchedulerTimeline { try await client.get("health/scheduler-timeline", query: ["days": "8"]) }
    func health() async throws -> SystemSchedulerHealth { try await client.get("health/system") }
}

struct DemoSystemSchedulerClient: SystemSchedulerClient {
    func timeline() throws -> SystemSchedulerTimeline {
        guard let file = Bundle.main.url(forResource: "system-scheduler-fixture", withExtension: "json") else { throw APIError.serverError(message: "Scheduler demo is unavailable.") }
        return try JSONDecoder().decode(SystemSchedulerTimeline.self, from: Data(contentsOf: file))
    }
    func health() -> SystemSchedulerHealth { .init(scheduler: .init(enabled: true, jobCount: 12, drift: .init(dbScheduleCount: 10, schedulerJobCount: 10, drifted: false))) }
}
