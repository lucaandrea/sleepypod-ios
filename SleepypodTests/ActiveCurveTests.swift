import XCTest
@testable import Sleepypod

@MainActor final class ActiveCurveTests: XCTestCase {
    private var power: CorePowerRow {
        .init(id: 1, side: "left", dayOfWeek: "thursday", onTime: "22:00", offTime: "07:15", onTemperature: 70, enabled: true, endAction: .turnOff, offDayOffset: 1)
    }
    private func curve(_ rows: CoreScheduleRows, at time: String = "2026-10-29T19:00:00Z") -> ActiveCurve? {
        ActiveCurve.recurring(schedules: Schedules(left: rows.projected, right: CoreScheduleRows().projected), side: .left,
                              timezone: "America/Los_Angeles", now: ISO8601DateFormatter().date(from: time)!)
    }
    func testPowerOnlyPlanDisplaysConstantTargetWithoutIntermediateSteps() throws {
        let result = try XCTUnwrap(curve(.init(power: [power])))
        XCTAssertEqual(result.constantTemperature, 70)
        XCTAssertEqual(result.setPoints.map(\.time), ["22:00"])
        XCTAssertEqual(result.bedtime, "22:00")
        XCTAssertEqual(result.wakeTime, "07:15")
    }
    func testFridayMorningKeepsThursdayNightAndFridayAfternoonDoesNot() {
        let rows = CoreScheduleRows(power: [power])
        XCTAssertEqual(curve(rows, at: "2026-10-30T14:00:00Z")?.constantTemperature, 70)
        XCTAssertNil(curve(rows, at: "2026-10-30T19:00:00Z"))
    }
    func testCoreMorningPhasesBelongToFollowingCalendarDay() throws {
        let rows = CoreScheduleRows(temperature: [
            .init(id: 2, side: "left", dayOfWeek: "thursday", time: "03:00", temperature: 90, enabled: true),
            .init(id: 3, side: "left", dayOfWeek: "friday", time: "03:00", temperature: 71, enabled: true),
            .init(id: 4, side: "left", dayOfWeek: "friday", time: "07:15", temperature: 82, enabled: true)
        ], power: [power])
        let result = try XCTUnwrap(curve(rows))
        XCTAssertEqual(result.setPoints.map(\.temperature), [70, 71])
        XCTAssertNil(result.constantTemperature)
    }
    func testExplicitBedtimeTargetWinsPowerDefault() {
        let rows = CoreScheduleRows(temperature: [.init(id: 2, side: "left", dayOfWeek: "thursday", time: "22:00", temperature: 69, enabled: true)], power: [power])
        XCTAssertEqual(curve(rows)?.constantTemperature, 69)
    }
    func testDisabledAmbiguousMaintainedOrUnboundedPowerDoesNotInventCurve() {
        var changed = power; changed.enabled = false
        XCTAssertNil(curve(.init(power: [changed])))
        changed = power; changed.id = 2
        XCTAssertNil(curve(.init(power: [power, changed])))
        changed = power; changed.endAction = .maintain
        XCTAssertNil(curve(.init(power: [changed])))
        changed = power; changed.offDayOffset = 0
        XCTAssertNil(curve(.init(power: [changed])))
    }
    func testSundayNightSurvivesFallBackIntoMondayMorning() {
        var changed = power; changed.dayOfWeek = "sunday"
        XCTAssertEqual(curve(.init(power: [changed]), at: "2026-11-02T15:00:00Z")?.constantTemperature, 70)
    }
    func testLegacyNightRetainsMorningPhaseAndInfersOvernightPower() {
        var left = CoreScheduleRows().projected; left.coreSnapshot = nil
        left.thursday.power = .init(on: "22:00", off: "07:00", onTemperature: 70, enabled: true)
        left.thursday.temperatures = ["03:00": 71]
        let result = ActiveCurve.recurring(schedules: .init(left: left, right: left), side: .left, timezone: "America/Los_Angeles", now: ISO8601DateFormatter().date(from: "2026-10-29T19:00:00Z")!)
        XCTAssertEqual(result?.setPoints.map(\.temperature), [70, 71])
    }
}
