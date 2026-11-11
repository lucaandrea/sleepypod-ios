import Foundation

protocol RecordingReadinessClient: Sendable {
    func read() async throws -> RecordingReadiness
}

struct CoreRecordingReadinessClient: RecordingReadinessClient {
    let transport: CoreRESTClient
    func read() async throws -> RecordingReadiness { try await transport.get("health/recording") }
}

struct DemoRecordingReadinessClient: RecordingReadinessClient {
    func read() -> RecordingReadiness {
        let now = (Date.now.timeIntervalSince1970 * 1000).rounded(.down)
        let checks = RecordingReadiness.requiredChecks.sorted().map { identifier in
            let unknown = identifier == "presence-history"
            return RecordingReadiness.Check(id: identifier, title: Self.titles[identifier] ?? identifier,
                state: unknown ? "unknown" : "ok",
                detail: unknown ? "Not enough simulated monitoring history to assess repeated interruptions." : "Simulated current check. This is not a measurement from your Pod.",
                nextStep: nil, observedAt: unknown ? nil : now)
        }
        return .init(apiVersion: 1, generatedAt: now, expiresAt: now + 60_000, state: "unknown",
                     summary: "Recording checks are incomplete", checks: checks, historicalWindowHours: 24)
    }
    private static let titles = [
        "sensor-cap": "Presence sensor", "sensor-piezo": "Heartbeat and movement signal",
        "sleep-detector": "Recording processor", "piezo-processor": "Vitals processor",
        "database": "Configuration database", "recording-database": "Saved recording access",
        "storage": "Recording storage", "presence-history": "Recent presence interruptions"
    ]
}
