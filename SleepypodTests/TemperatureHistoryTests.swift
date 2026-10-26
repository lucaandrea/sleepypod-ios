import XCTest
@testable import Sleepypod

@MainActor final class TemperatureHistoryTests: XCTestCase {
    private func date(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }
    private var start: Date { date("2026-10-25T01:00:00Z") }
    private var end: Date { date("2026-10-25T16:00:00Z") }
    func testHistoryWindowPreservesBothNightsAcrossDaylightSaving() {
        let value = TemperatureHistory(schedules: nil, timezone: "America/Los_Angeles", now: date("2026-11-01T07:00:00Z"))
        XCTAssertEqual(value.tonight.range.upperBound.timeIntervalSince(value.tonight.range.lowerBound), 16 * 3600)
        XCTAssertEqual(value.range.upperBound.timeIntervalSince(value.range.lowerBound), 40 * 3600)
    }
    func testWallClockResolutionPreservesSpringMinutesAndUsesFirstRepeatedHour() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(TemperatureTimeline.date("02:30", on: date("2026-03-08T08:00:00Z"), calendar: calendar), date("2026-03-08T10:30:00Z"))
        XCTAssertEqual(TemperatureTimeline.date("01:30", on: date("2026-11-01T07:00:00Z"), calendar: calendar), date("2026-11-01T08:30:00Z"))
        calendar.timeZone = TimeZone(identifier: "America/Havana")!
        XCTAssertNil(TemperatureTimeline.date("00:30", on: date("2026-03-08T06:00:00Z"), calendar: calendar))
    }
    func testNextDayPowerOffResolvesOnItsOwnDayAfterSpringTransition() async throws {
        var schedules = try await MockClient().getSchedules()
        for day in DayOfWeek.allCases { schedules.left[day].power.enabled = false; schedules.left[day].temperatures = [:] }
        schedules.left.sunday.power = .init(on: "22:00", off: "02:30", endAction: .turnOff, offDayOffset: 1, onTemperature: 72, enabled: true)
        let timeline = TemperatureTimeline(schedules: schedules, timezone: "America/Los_Angeles", now: date("2026-03-09T06:00:00Z"))
        XCTAssertEqual(timeline.state(for: .left, at: date("2026-03-09T09:29:00Z")).powered, true)
        XCTAssertEqual(timeline.state(for: .left, at: date("2026-03-09T09:30:00Z")).powered, false)
    }
    func testPresencePreservesExitAndCapsOpenSessionAtObservedTime() {
        var record = SleepRecord(id: 1, side: "left", enteredBed: start, leftBed: nil)
        let first = start.timeIntervalSince1970
        record.presentIntervals = "[[\(first),\(first + 3600)],[\(first + 7200),null]]"
        let result = TemperatureHistory.presence([record], side: .left, in: start...end, now: start.addingTimeInterval(10800))
        XCTAssertEqual(result, [.init(start: start, end: start.addingTimeInterval(3600)), .init(start: start.addingTimeInterval(7200), end: start.addingTimeInterval(10800))])
        XCTAssertTrue(TemperatureHistory.presence([record], side: .right, in: start...end, now: end).isEmpty)
    }
    func testPresenceAcceptsMillisecondsAndRejectsMalformedReportedIntervals() {
        var record = SleepRecord(id: 1, side: "left", enteredBed: start, leftBed: end)
        let first = start.timeIntervalSince1970 * 1000
        record.presentIntervals = "[[\(first),\(first + 3600000)]]"
        XCTAssertEqual(TemperatureHistory.presence([record], side: .left, in: start...end, now: end).first?.end, start.addingTimeInterval(3600))
        record.presentIntervals = "broken"
        XCTAssertTrue(TemperatureHistory.presence([record], side: .left, in: start...end, now: end).isEmpty)
        record.presentIntervals = nil
        XCTAssertEqual(TemperatureHistory.presence([record], side: .left, in: start...end, now: end), [.init(start: start, end: end)])
    }
    func testMalformedCoreIntervalArrayDoesNotBecomeContinuousOccupancy() throws {
        let payload = "{\"id\":1,\"side\":\"left\",\"enteredBedAt\":\(Int(start.timeIntervalSince1970)),\"leftBedAt\":null,\"presentIntervals\":[[\"invalid\",null]]}"
        let record = try JSONDecoder().decode(SleepRecord.self, from: Data(payload.utf8))
        XCTAssertNotNil(record.presentIntervals)
        XCTAssertTrue(TemperatureHistory.presence([record], side: .left, in: start...end, now: end).isEmpty)
    }
    func testMissingIntervalsDoNotFillReportedExits() {
        var record = SleepRecord(id: 1, side: "left", enteredBed: start, leftBed: end, timesExitedBed: 2)
        XCTAssertTrue(TemperatureHistory.presence([record], side: .left, in: start...end, now: end).isEmpty)
        record.presentIntervals = "[]"
        XCTAssertTrue(TemperatureHistory.presence([record], side: .left, in: start...end, now: end).isEmpty)
    }
    func testSleepRecordKeepsArrayIntervalsReturnedByCore() throws {
        let payload = "{\"id\":1,\"side\":\"left\",\"enteredBedAt\":\(Int(start.timeIntervalSince1970)),\"leftBedAt\":null,\"presentIntervals\":[[\(start.timeIntervalSince1970),null]]}"
        let record = try JSONDecoder().decode(SleepRecord.self, from: Data(payload.utf8))
        XCTAssertNotNil(record.presentIntervals)
        XCTAssertEqual(TemperatureHistory.presence([record], side: .left, in: start...end, now: end), [.init(start: start, end: end)])
    }
    func testPowerDoesNotFillMissingTargetBucketsOrFutureTime() {
        let first = start.timeIntervalSince1970 * 1000
        let history = SystemThermalHistory(range: "24h", from: first, to: end.timeIntervalSince1970 * 1000, bucketSec: 60,
            points: [.init(timestamp: first + 30000, values: [.leftTarget: 68]), .init(timestamp: first + 90000, values: [:]), .init(timestamp: first + 150000, values: [.leftTarget: 70])], powerOn: [], available: [:], bedTargetSince: first)
        let result = TemperatureHistory.power(history, side: .left, in: start...end, now: start.addingTimeInterval(150))
        XCTAssertEqual(result, [.init(start: start, end: start.addingTimeInterval(60)), .init(start: start.addingTimeInterval(120), end: start.addingTimeInterval(150))])
        XCTAssertTrue(TemperatureHistory.power(history, side: .right, in: start...end, now: end).isEmpty)
    }
    func testTimingComparisonsRequireRecordedPresenceAndFifteenMinuteDifference() async throws {
        var schedules = try await MockClient().getSchedules()
        for side in Side.allCases {
            var weekly = schedules.schedule(for: side)
            for day in DayOfWeek.allCases { weekly[day].temperatures = [:]; weekly[day].power.enabled = false }
            schedules.setSchedule(weekly, for: side)
        }
        schedules.left.friday.temperatures = ["22:00": 74]
        schedules.left.saturday.temperatures = ["07:00": 80]
        let timeline = TemperatureTimeline(schedules: schedules, timezone: "America/Los_Angeles", now: date("2026-10-24T09:00:00Z"))
        let first = date("2026-10-24T05:00:00Z"), last = date("2026-10-24T14:00:00Z")
        XCTAssertTrue(TemperatureHistory.comparisons(timeline: timeline, side: .left, presence: []).isEmpty)
        let short = TemperatureHistory.comparisons(timeline: timeline, side: .left, presence: [.init(start: first.addingTimeInterval(14 * 60), end: last.addingTimeInterval(14 * 60))])
        XCTAssertTrue(short.isEmpty)
        let result = TemperatureHistory.comparisons(timeline: timeline, side: .left, presence: [.init(start: first.addingTimeInterval(30 * 60), end: last.addingTimeInterval(20 * 60))])
        XCTAssertEqual(result.map(\.kind), [.laterEntry, .laterExit]); XCTAssertEqual(result.map(\.minutes), [30, 20])
        XCTAssertTrue(TemperatureHistory.comparisons(timeline: timeline, side: .right, presence: [.init(start: first, end: last)]).isEmpty)
    }
    func testRunOnceStartsImmediatelyAndLaterTargetsUsePodClock() {
        let started = date("2026-10-25T05:34:00Z")
        let session = RunOnceSession(id: 1, side: "left", setPoints: [.init(time: "23:00", temperature: 72), .init(time: "02:00", temperature: 68)], wakeTime: "07:00", startedAt: Int(started.timeIntervalSince1970), expiresAt: Int(date("2026-10-25T14:00:00Z").timeIntervalSince1970), status: "active")
        let points = TemperatureHistory.runOnce(session, side: .left, timezone: "America/Los_Angeles")
        XCTAssertEqual(points.map(\.date), [started, date("2026-10-25T09:00:00Z"), date("2026-10-25T14:00:00Z")])
        XCTAssertEqual(TemperatureHistory.runOnceTarget(points, at: started), 72)
        XCTAssertEqual(TemperatureHistory.runOnceTarget(points, at: date("2026-10-25T10:00:00Z")), 68)
        XCTAssertNil(TemperatureHistory.runOnceTarget(points, at: session.expiresAtDate))
        XCTAssertTrue(TemperatureHistory.runOnce(session, side: .right, timezone: "UTC").isEmpty)
    }
    func testRunOnceWithDuplicateClocksDoesNotInventAnOrder() {
        let session = RunOnceSession(id: 1, side: "left", setPoints: [.init(time: "22:00", temperature: 72), .init(time: "22:00", temperature: 68)], wakeTime: "07:00", startedAt: Int(start.timeIntervalSince1970), expiresAt: Int(end.timeIntervalSince1970), status: "active")
        XCTAssertTrue(TemperatureHistory.runOnce(session, side: .left, timezone: "America/Los_Angeles").isEmpty)
    }
    func testWorkspaceResetDiscardsLateControllerResults() async {
        let client = HistorySuspendingClient()
        let workspace = TemperatureHistoryWorkspace()
        let task = Task { await workspace.load(client: client, range: start...end, now: end) }
        while !(await client.waiting) { await Task.yield() }
        workspace.reset(); await client.resume(); await task.value
        XCTAssertNil(workspace.result); XCTAssertFalse(workspace.loading)
    }
}
private actor HistorySuspendingClient: TemperatureHistoryClient {
    private var continuation: CheckedContinuation<TemperatureHistoryResult, Never>?
    var waiting: Bool { continuation != nil }
    func load(from: Date, to: Date) async -> TemperatureHistoryResult {
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() { continuation?.resume(returning: .init(thermal: .init(), records: [:], sessions: [:])); continuation = nil }
}
