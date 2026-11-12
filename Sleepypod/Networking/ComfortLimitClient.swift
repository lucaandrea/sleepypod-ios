import Foundation

protocol ComfortLimitClient: Sendable {
    func read(side: Side) async throws -> ComfortLimitPage
    func save(_ change: ComfortLimitWrite) async throws -> ComfortLimitPage
}

struct CoreComfortLimitClient: ComfortLimitClient {
    let transport: CoreRESTClient
    func read(side: Side) async throws -> ComfortLimitPage {
        try await transport.get("v1/temperature/comfort-limit", query: ["side": side.rawValue])
    }
    func save(_ change: ComfortLimitWrite) async throws -> ComfortLimitPage {
        try await transport.put("v1/temperature/comfort-limit", body: change, returning: ComfortLimitPage.self)
    }
}

/// Practice is in-memory and never connects to a Pod or changes its temperature.
actor DemoComfortLimitClient: ComfortLimitClient {
    private var revisions: [Side: Int] = [:]
    private var configurations: [Side: ComfortLimitConfiguration] = [:]
    func read(side: Side) -> ComfortLimitPage {
        let alarm = Calendar.current.nextDate(after: .now, matching: DateComponents(hour: 7, minute: 0), matchingPolicy: .nextTime) ?? .now.addingTimeInterval(86_400)
        return .init(apiVersion: 1, side: side, sourceSide: side, revision: revisions[side] ?? 0,
            config: configurations[side] ?? .init(enabled: false, minF: 68, maxF: 72),
            wake: .init(startsAt: alarm.addingTimeInterval(-1800).timeIntervalSince1970 * 1000,
                        alarmAt: alarm.timeIntervalSince1970 * 1000, targetF: 105, timeZone: TimeZone.current.identifier),
            wakeAvailable: true)
    }
    func save(_ change: ComfortLimitWrite) throws -> ComfortLimitPage {
        guard change.config.isValid, change.side == change.expectedSourceSide,
              change.expectedRevision == (revisions[change.side] ?? 0) else { throw ComfortLimitError.staleDraft }
        revisions[change.side] = change.expectedRevision + 1
        configurations[change.side] = change.config
        return read(side: change.side)
    }
}
