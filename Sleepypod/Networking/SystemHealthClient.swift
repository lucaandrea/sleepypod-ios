import Foundation

protocol SystemHealthClient: Sendable {
    func path() async throws -> SystemHealthPath
    func history() async throws -> SystemHealthHistory
    func restart(unit: String) async throws -> HealthServiceRestart
}

struct CoreSystemHealthClient: SystemHealthClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient {
        get throws { guard let transport else { throw APIError.noBaseURL }; return transport }
    }
    func path() async throws -> SystemHealthPath { try await client.get("health/data-path") }
    func history() async throws -> SystemHealthHistory { try await client.get("health/history") }
    func restart(unit: String) async throws -> HealthServiceRestart {
        guard SystemHealthPath.restartableUnits.contains(unit) else { throw APIError.notSupported("This service cannot be restarted from Health.") }
        return try await client.post("health/restart-service", body: ["unit": unit], returning: HealthServiceRestart.self)
    }
}

actor DemoSystemHealthClient: SystemHealthClient {
    private var restarted = false
    func path() -> SystemHealthPath {
        let now = Date.now.timeIntervalSince1970 * 1000
        let specification = [
            ("sensor-piezo", "sensors", "Piezo"), ("sensor-cap", "sensors", "Capacitance"), ("sensor-temp", "sensors", "Temperature"),
            ("frames", "hardware", "Frame source"), ("dac", "hardware", "DAC socket"),
            ("piezo-processor", "services", "Piezo processor"), ("sleep-detector", "services", "Sleep detector"), ("environment-monitor", "services", "Environment monitor"), ("dac-monitor", "services", "DAC monitor"),
            ("database", "core", "Database"), ("scheduler", "core", "Scheduler"),
            ("out-vitals", "outputs", "Vitals"), ("out-sleep", "outputs", "Sleep sessions"), ("out-temp", "outputs", "Bed temperature"), ("out-live", "outputs", "Live stream")
        ]
        let nodes = specification.map { id, stage, label in
            let stalled = !restarted && ["piezo-processor", "out-vitals"].contains(id)
            let unit = SystemHealthPath.restartableUnits.contains("sleepypod-\(id).service") ? "sleepypod-\(id).service" : nil
            return SystemHealthPath.Node(id: id, stage: stage, label: label, status: stalled ? .stale : .ok, metric: stalled ? "24 minutes ago" : "2 seconds ago", detail: stalled ? "Simulated service is running but has not produced recent vitals." : "Simulated data is flowing through this stage.", lastOutputAt: now - (stalled ? 1_440_000 : 2000), unit: unit, path: unit)
        }
        let edges = [("sensor-piezo", "frames"), ("sensor-cap", "frames"), ("sensor-temp", "frames"), ("frames", "piezo-processor"), ("frames", "sleep-detector"), ("frames", "environment-monitor"), ("dac", "dac-monitor"), ("piezo-processor", "database"), ("sleep-detector", "database"), ("environment-monitor", "database"), ("dac-monitor", "database"), ("database", "out-vitals"), ("database", "out-sleep"), ("database", "out-temp"), ("scheduler", "out-temp"), ("frames", "out-live")].map { from, to in
            SystemHealthPath.Edge(from: from, to: to, state: !restarted && (from == "piezo-processor" || to == "out-vitals") ? "stalled" : "flowing")
        }
        let fix = SystemHealthPath.Fix(kind: "restart", unit: "sleepypod-piezo-processor.service", label: "Restart piezo processor", sides: nil, hint: nil, tab: nil)
        return .init(at: now, occupancy: ["left": "occupied", "right": "empty"], nodes: nodes, edges: edges, verdict: .init(tone: restarted ? "ok" : "warn", headline: restarted ? "Simulated data is flowing" : "Simulated vitals stopped at the piezo processor", nodeId: restarted ? nil : "piezo-processor", lastGoodId: restarted ? "out-vitals" : "frames", fix: restarted ? nil : fix, also: []))
    }
    func history() -> SystemHealthHistory {
        let now = Date.now.timeIntervalSince1970 * 1000, day = 86_400_000.0
        let start = now - day, interruption = now - 3_600_000
        let common: [SystemHealthHistory.Run] = [.init(status: .ok, start: start + 60_000, end: interruption - 60_000), .init(status: .stale, start: interruption, end: interruption + 120_000), .init(status: .ok, start: interruption + 120_000, end: now)]
        let checks = [SystemHealthHistory.Check(id: "piezo-processor", label: "Piezo processor", runs: common, healthyShare: 0.98, incidents: 1), .init(id: "out-vitals", label: "Vitals", runs: common, healthyShare: 0.98, incidents: 1), .init(id: "sensor-cap", label: "Capacitance", runs: [.init(status: .ok, start: start + 60_000, end: now)], healthyShare: 1, incidents: 0), .init(id: "sensor-temp", label: "Temperature", runs: [.init(status: .idle, start: start + 60_000, end: now)], healthyShare: 1, incidents: 0)]
        return .init(from: start, to: now, recordedSince: start + 60_000, checks: checks, incidents: [
            .init(checkId: "piezo-processor", label: "Piezo processor", status: .stale, start: interruption, end: interruption + 120_000, detail: "Simulated two-minute interruption; this is not a Pod event."),
            .init(checkId: "out-vitals", label: "Vitals", status: .stale, start: interruption, end: interruption + 120_000, detail: nil)
        ], gaps: [.init(start: start, end: start + 60_000), .init(start: interruption - 60_000, end: interruption)])
    }
    func restart(unit: String) throws -> HealthServiceRestart {
        guard SystemHealthPath.restartableUnits.contains(unit) else { throw APIError.notSupported("Unsupported simulated restart") }
        restarted = true
        return .init(ok: true, message: "Simulated restart accepted")
    }
}
