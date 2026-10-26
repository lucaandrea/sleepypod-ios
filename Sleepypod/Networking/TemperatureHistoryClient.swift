import Foundation

struct TemperatureHistoryResult: Sendable {
    let thermal: TemperatureContextValue<SystemThermalHistory>
    let records: [Side: TemperatureContextValue<[SleepRecord]>]
    let sessions: [Side: TemperatureContextValue<RunOnceSession>]
}
protocol TemperatureHistoryClient: Sendable {
    func load(from: Date, to: Date) async -> TemperatureHistoryResult
}
struct CoreTemperatureHistoryClient: TemperatureHistoryClient {
    let transport: CoreRESTClient
    func load(from: Date, to: Date) async -> TemperatureHistoryResult {
        async let thermal = TemperatureContextValue<SystemThermalHistory>.capture {
            let value: SystemThermalHistory = try await transport.get("health/thermal-history", query: ["range": "24h"])
            guard value.range == "24h", value.from.isFinite, value.to.isFinite, value.from > 0, value.to > value.from,
                  value.bucketSec.isFinite, (0...3600).contains(value.bucketSec), value.bucketSec > 0,
                  value.points.count <= 5000, value.points.allSatisfy({ $0.timestamp.isFinite && (value.from...value.to).contains($0.timestamp) }) else {
                throw APIError.serverError(message: "The controller returned an invalid power history window.")
            }
            return value
        }
        async let left = records(.left, from: from, to: to)
        async let right = records(.right, from: from, to: to)
        async let leftRun = session(.left)
        async let rightRun = session(.right)
        return await .init(thermal: thermal, records: [.left: left, .right: right], sessions: [.left: leftRun, .right: rightRun])
    }
    private func records(_ side: Side, from: Date, to: Date) async -> TemperatureContextValue<[SleepRecord]> {
        await .capture {
            let rows: [SleepRecord] = try await transport.get("biometrics/sleep-records", query: ["side": side.rawValue, "startDate": from.ISO8601Format(), "endDate": to.ISO8601Format(), "limit": "100"])
            guard rows.allSatisfy({ $0.side == side.rawValue && $0.enteredBedDate >= from && $0.enteredBedDate <= to }) else {
                throw APIError.serverError(message: "Sleep history did not match the selected side and dates.")
            }
            return rows
        }
    }
    private func session(_ side: Side) async -> TemperatureContextValue<RunOnceSession> {
        await .capture {
            let session: RunOnceSession? = try await transport.get("run-once/active", query: ["side": side.rawValue])
            if let session {
                guard session.side == side.rawValue, session.status == "active", session.id > 0, session.startedAt > 0,
                      session.expiresAt > session.startedAt, (1...96).contains(session.setPoints.count),
                      Set(session.setPoints.map(\.time)).count == session.setPoints.count,
                      session.setPoints.allSatisfy({ AutomationCondition.validClock($0.time) && (55...110).contains($0.temperature) }) else {
                    throw APIError.serverError(message: "The controller returned an invalid Run Once session.")
                }
            }
            return session
        }
    }
}
struct DemoTemperatureHistoryClient: TemperatureHistoryClient {
    var sessions: [Side: RunOnceSession] = [:]
    var unavailable = false
    func load(from: Date, to: Date) async -> TemperatureHistoryResult {
        if unavailable {
            return .init(thermal: .init(error: "Example controller is offline."), records: [.left: .init(error: "Sleep history unavailable."), .right: .init(error: "Sleep history unavailable.")], sessions: [.left: .init(error: "Run Once unavailable."), .right: .init(error: "Run Once unavailable.")])
        }
        let thermal = await DemoSystemThermalClient().history(.day)
        let left = try? await MockClient().getSleepRecords(side: .left, start: from, end: to)
        let right = try? await MockClient().getSleepRecords(side: .right, start: from, end: to)
        return .init(thermal: .init(value: thermal), records: [.left: .init(value: left), .right: .init(value: right)], sessions: [.left: .init(value: sessions[.left]), .right: .init(value: sessions[.right])])
    }
}
