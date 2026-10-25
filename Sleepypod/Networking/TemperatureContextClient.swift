import Foundation

protocol TemperatureContextClient: Sendable {
    func load(side: Side) async -> TemperatureContextResult
}

struct CoreTemperatureContextClient: TemperatureContextClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }

    func load(side: Side) async -> TemperatureContextResult {
        async let room = TemperatureContextValue<RoomSnapshot>.capture {
            try await client.get("environment/bed-temp/latest", query: ["unit": "C"])
        }
        async let light = TemperatureContextValue<LightSnapshot>.capture {
            try await client.get("environment/ambient-light/latest")
        }
        async let sleep = TemperatureContextValue<RecentSleepContext>.capture { try await recentSleep(side: side) }
        return await TemperatureContextResult(room: room, light: light, sleep: sleep)
    }

    private var client: CoreRESTClient {
        get throws { guard let transport else { throw APIError.noBaseURL }; return transport }
    }

    /// Limit the averages to the actual sleep session; an open session uses the server's clock.
    private func recentSleep(side: Side) async throws -> RecentSleepContext? {
        let transport = try client
        guard let record: SleepRecord = try await transport.get("biometrics/sleep-records/latest", query: ["side": side.rawValue]) else { return nil }
        guard record.side == side.rawValue, record.enteredBedDate.timeIntervalSince1970 > 0,
              record.completedAt.map({ $0 >= record.enteredBedDate }) ?? true else {
            throw APIError.serverError(message: "The controller returned an invalid sleep session. Reload to try again.")
        }
        var query = ["side": side.rawValue, "startDate": record.enteredBedDate.ISO8601Format()]
        if let end = record.completedAt { query["endDate"] = end.ISO8601Format() }
        let parameters = query
        let vitals = await TemperatureContextValue<RecentSleepVitals>.capture {
            try await transport.get("biometrics/vitals/summary", query: parameters)
        }
        return RecentSleepContext(record: record, vitals: vitals)
    }
}

struct DemoTemperatureContextClient: TemperatureContextClient {
    var scenario = "complete"
    func load(side: Side) async -> TemperatureContextResult {
        if scenario == "empty" { return .init(room: .init(), light: .init(), sleep: .init()) }
        let now = Date.now
        let measured = scenario == "stale" ? now.addingTimeInterval(-600) : now
        let room = RoomSnapshot(timestamp: measured.ISO8601Format(), ambientTemp: 25, humidity: 55,
                                leftOuterTemp: 25, leftCenterTemp: 26.5, leftInnerTemp: 27,
                                rightOuterTemp: 27, rightCenterTemp: 28, rightInnerTemp: 26)
        let record = (try? await MockClient().getSleepRecords(side: side, start: nil, end: nil))?.max { $0.enteredBedDate < $1.enteredBedDate }
        let vitals = RecentSleepVitals(avgHeartRate: 58, avgHRV: 44, avgBreathingRate: 14, recordCount: 120,
                                      provenance: .init(configurationCount: 1, unknownConfigurationRows: 0, hrvMetricId: "rmssd", hrvAggregation: "single_definition"))
        return TemperatureContextResult(room: .init(value: room),
                                        light: scenario == "partial" ? .init(error: "The light sensor is offline.") : .init(value: .init(timestamp: measured.ISO8601Format(), lux: 4)),
                                        sleep: .init(value: record.map { .init(record: $0, vitals: scenario == "partial" ? .init(error: "The vitals service is offline.") : .init(value: vitals)) }))
    }
}
