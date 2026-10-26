import Foundation

protocol CalendarScheduleClient: Sendable {
    func rows(side: Side) async throws -> CoreScheduleRows
    func apply(_ review: CalendarScheduleControl) async throws
}
struct CoreCalendarScheduleClient: CalendarScheduleClient {
    let transport: CoreRESTClient
    func rows(side: Side) async throws -> CoreScheduleRows { try await transport.get("schedules", query: ["side": side.rawValue, "unit": "F"]) }
    func apply(_ review: CalendarScheduleControl) async throws {
        struct Receipt: Decodable, Sendable { let success: Bool }
        let receipt = try await transport.post("schedules/batch", body: review.batch, returning: Receipt.self)
        guard receipt.success else { throw APIError.serverError(message: "The controller did not confirm the schedule change. Reload before retrying.") }
    }
}

/// Demo retains disabled rows in the shared schedule snapshot, so resuming can restore them.
actor DemoCalendarScheduleClient: CalendarScheduleClient {
    let api: any SleepypodProtocol
    init(api: any SleepypodProtocol) { self.api = api }
    func rows(side: Side) async throws -> CoreScheduleRows {
        let weekly = try await api.getSchedules().schedule(for: side)
        if let snapshot = weekly.coreSnapshot { return snapshot }
        var result = CoreScheduleRows(), identifier = side == .left ? 0 : 10000
        for day in DayOfWeek.allCases {
            let daily = weekly[day]
            for (time, temperature) in daily.temperatures.sorted(by: { $0.key < $1.key }) {
                identifier += 1
                result.temperature.append(.init(id: identifier, side: side.rawValue, dayOfWeek: day.rawValue, time: time, temperature: Double(temperature), enabled: true))
            }
            identifier += 1
            result.power.append(.init(id: identifier, side: side.rawValue, dayOfWeek: day.rawValue, onTime: daily.power.on, offTime: daily.power.off, onTemperature: Double(daily.power.onTemperature), enabled: daily.power.enabled, endAction: daily.power.endAction, offDayOffset: daily.power.offDayOffset))
            identifier += 1
            result.alarm.append(.init(id: identifier, side: side, dayOfWeek: day, time: daily.alarm.time, vibrationIntensity: daily.alarm.vibrationIntensity, vibrationPattern: daily.alarm.vibrationPattern, duration: daily.alarm.duration, alarmTemperature: Double(daily.alarm.alarmTemperature), enabled: daily.alarm.enabled, wakeWindow: daily.alarm.wakeWindow, snoozeDuration: daily.alarm.snoozeDuration, snoozeTaper: daily.alarm.snoozeTaper))
        }
        return result
    }
    func apply(_ review: CalendarScheduleControl) async throws {
        let latest = try await rows(side: review.side)
        guard CalendarScheduleControl.same(latest, review.original) else { throw APIError.serverError(message: "The example schedules changed. Reload them.") }
        var schedules = try await api.getSchedules()
        schedules.setSchedule(review.desired.projected, for: review.side)
        _ = try await api.updateSchedules(schedules, days: nil)
    }
}
