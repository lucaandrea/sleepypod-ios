import Foundation

protocol SensorDiagnosticsClient: Sendable {
    func occupancy() async throws -> SensorOccupancy
    func bed() async throws -> SensorBedReading?
    func freezer() async throws -> SensorFreezerReading?
    func water() async throws -> WaterLevelReading?
    func history(start: Date, end: Date, limit: Int) async throws -> [BedTempReading]
    func summary(start: Date, end: Date) async throws -> SensorEnvironmentSummary
    func flow(hours: Int) async throws -> [SensorFlowReading]
}

struct CoreSensorDiagnosticsClient: SensorDiagnosticsClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient {
        get throws { guard let transport else { throw APIError.noBaseURL }; return transport }
    }
    func occupancy() async throws -> SensorOccupancy { try await client.get("biometrics/occupancy") }
    func bed() async throws -> SensorBedReading? { try await client.get("environment/bed-temp/latest", query: ["unit": "C"]) }
    func freezer() async throws -> SensorFreezerReading? { try await client.get("environment/freezer-temp/latest", query: ["unit": "C"]) }
    func water() async throws -> WaterLevelReading? { try await client.get("water-level/latest") }
    func history(start: Date, end: Date, limit: Int) async throws -> [BedTempReading] {
        try await client.get("environment/bed-temp", query: ["startDate": start.ISO8601Format(), "endDate": end.ISO8601Format(), "limit": String(limit), "unit": "C"])
    }
    func summary(start: Date, end: Date) async throws -> SensorEnvironmentSummary {
        try await client.get("environment/summary", query: ["startDate": start.ISO8601Format(), "endDate": end.ISO8601Format(), "unit": "C"])
    }
    func flow(hours: Int) async throws -> [SensorFlowReading] { try await client.get("water-level/flow", query: ["hours": String(hours)]) }
}

struct DemoSensorDiagnosticsClient: SensorDiagnosticsClient {
    func occupancy() -> SensorOccupancy {
        func side(_ occupied: Bool) -> SensorOccupancy.BedSide {
            .init(occupied: occupied, available: true, classification: occupied ? "person" : "none",
                  movement: .init(active: occupied, peakScore: occupied ? 42 : 0),
                  level: .init(active: occupied, deviation: occupied ? 25 : 0, threshold: 12, ageMs: 500, zoneDeviations: [12, 8, 5], zones: occupied ? 3 : 0),
                  vitals: .init(heartRate: occupied ? 62 : nil, breathingRate: occupied ? 15 : nil, humanRange: occupied ? true : nil))
        }
        return .init(left: side(true), right: side(false))
    }
    func bed() -> SensorBedReading? {
        .init(timestamp: Date.now.addingTimeInterval(-20).ISO8601Format(), ambientTemp: 22, mcuTemp: 33, humidity: 45,
              leftOuterTemp: 30.5, leftCenterTemp: 31.2, leftInnerTemp: 29.8, rightOuterTemp: 29, rightCenterTemp: 29.8, rightInnerTemp: 28.5)
    }
    func freezer() -> SensorFreezerReading? {
        .init(timestamp: Date.now.addingTimeInterval(-20).ISO8601Format(), ambientTemp: 24, heatsinkTemp: 36, leftWaterTemp: 21, rightWaterTemp: 23)
    }
    func water() -> WaterLevelReading? { .init(id: 1, level: "ok", rawValue: nil, timestamp: Date.now.ISO8601Format()) }
    func history(start: Date, end: Date, limit: Int) -> [BedTempReading] {
        let count = min(1440, limit), step = end.timeIntervalSince(start) / Double(max(1, count - 1))
        return (0..<count).map { index in
            let wave = sin(Double(index) / 12)
            return .init(timestamp: start.addingTimeInterval(Double(index) * step).ISO8601Format(), ambientTemp: 22 + wave,
                         humidity: index == 40 ? nil : 45 + wave * 4, leftCenterTemp: index == 40 ? nil : 28 + wave,
                         leftInnerTemp: nil, rightCenterTemp: 29 - wave, rightInnerTemp: nil)
        }
    }
    func summary(start: Date, end: Date) -> SensorEnvironmentSummary {
        .init(bedTemp: .init(avgAmbientTemp: 22, minAmbientTemp: 21, maxAmbientTemp: 23, avgHumidity: 45, avgLeftCenterTemp: 28, avgRightCenterTemp: 29, recordCount: 120))
    }
    func flow(hours: Int) -> [SensorFlowReading] {
        let end = Date.now
        let count = min(10080, hours * 60)
        return (0..<count).map { index -> SensorFlowReading in
            let elapsed = Double(count - 1 - index) * 60
            let wave = sin(Double(index) / 8) * 100
            let flow: Double? = index == 45 ? nil : 2400 + wave
            let rpm: Double? = index == 45 ? nil : 2000 + wave
            return SensorFlowReading(timestamp: end.addingTimeInterval(-elapsed).ISO8601Format(),
                                     leftFlowrateCd: flow, rightFlowrateCd: 2500, leftPumpRpm: rpm, rightPumpRpm: 2100)
        }
    }
}
