import Foundation

protocol SystemThermalClient: Sendable {
    func snapshot() async throws -> SystemThermalSnapshot
    func history(_ range: ThermalRange) async throws -> SystemThermalHistory
}

struct CoreSystemThermalClient: SystemThermalClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient {
        get throws { guard let transport else { throw APIError.noBaseURL }; return transport }
    }
    func snapshot() async throws -> SystemThermalSnapshot { try await client.get("health/thermal") }
    func history(_ range: ThermalRange) async throws -> SystemThermalHistory {
        guard range != .live else { throw APIError.notSupported("Live history is collected in the app.") }
        return try await client.get("health/thermal-history", query: ["range": range.rawValue])
    }
}

actor DemoSystemThermalClient: SystemThermalClient {
    func snapshot() -> SystemThermalSnapshot {
        .init(pumpStallProtectionEnabled: true, reportsPumpSpeed: true, heatsinkTempF: 91, ambientTempF: 74, sides: [
            .init(side: .left, isPowered: true, targetTempF: 68, currentTempF: 72, isAlarmVibrating: false, poweredOnAt: Date.now.addingTimeInterval(-3600).ISO8601Format(), pumpRpm: 2300, flowrate: 1.2, readingAgeSec: 8, waterTempF: 69, bedSurfaceTempF: 75, guardBlocked: false, verdict: "delivering", note: "Simulated readings"),
            .init(side: .right, isPowered: true, targetTempF: 80, currentTempF: 77, isAlarmVibrating: false, poweredOnAt: Date.now.addingTimeInterval(-1800).ISO8601Format(), pumpRpm: 2200, flowrate: 1.1, readingAgeSec: 8, waterTempF: 79, bedSurfaceTempF: 78, guardBlocked: false, verdict: "delivering", note: "Simulated readings")
        ])
    }
    func history(_ range: ThermalRange) -> SystemThermalHistory {
        let end = Date.now.timeIntervalSince1970 * 1000, start = end - range.seconds * 1000
        let points = (0...120).map { index -> ThermalHistoryPoint in
            let phase = Double(index) / 10, variation = sin(phase)
            var values: [ThermalSignal: Double] = [.leftBed: 71 + variation, .rightBed: 77 + variation, .leftTarget: 68, .rightTarget: 80, .leftWater: 69 + variation, .rightWater: 79 + variation, .leftSurface: 75 + variation, .rightSurface: 78 + variation, .leftRpm: 2300 + variation * 100, .rightRpm: 2200 + variation * 100, .heatsink: 91 + variation * 2, .ambient: 74 + variation / 2]
            if (45...50).contains(index) { values = [:] }
            return .init(timestamp: start + Double(index) / 120 * (end - start), values: values)
        }
        return .init(range: range.rawValue, from: start, to: end, bucketSec: range.seconds / 120, points: points, powerOn: [.init(side: .left, at: start + 0.2 * (end - start)), .init(side: .right, at: start + 0.3 * (end - start))], available: Dictionary(uniqueKeysWithValues: ThermalPanel.allCases.map { ($0.rawValue, true) }), bedTargetSince: start)
    }
}
