import Foundation

protocol SystemDashboardClient: Sendable {
    func runtime() async throws -> SystemRuntimeFacts
    func maintenance() async throws -> SystemMaintenanceFacts
}
struct CoreSystemDashboardClient: SystemDashboardClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient {
        get throws { guard let transport else { throw APIError.noBaseURL }; return transport }
    }
    func runtime() async throws -> SystemRuntimeFacts { try await client.get("health/performance") }
    func maintenance() async throws -> SystemMaintenanceFacts { try await client.get("health/maintenance") }
}
struct DemoSystemDashboardClient: SystemDashboardClient {
    func runtime() -> SystemRuntimeFacts {
        .init(uptimeSeconds: 195_420, rssBytes: 196_000_000,
              memory: .init(heapTotalBytes: 83_000_000, heapUsedBytes: 62_000_000, externalBytes: 18_000_000, arrayBuffersBytes: 12_000_000),
              startup: [.init(name: "Database", elapsedMs: 50, durationMs: 18), .init(name: "Sensor stream", elapsedMs: 930, durationMs: 280)],
              sensorSource: "nats", firstFrameMs: 1080, eventLoop: .init(meanMs: 10, p95Ms: 14, maxMs: 22))
    }
    func maintenance() -> SystemMaintenanceFacts {
        .init(pumpStallProtectionEnabled: false, reportsPumpSpeed: true, primePodDaily: false, primePodTime: nil,
              lastPrimeAt: Date.now.addingTimeInterval(-8 * 86400).timeIntervalSince1970 * 1000,
              firstPrimeRecordedAt: Date.now.addingTimeInterval(-90 * 86400).timeIntervalSince1970 * 1000)
    }
}
