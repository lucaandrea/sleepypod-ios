import XCTest
@testable import Sleepypod

@MainActor final class SleepPeriodParityTests: XCTestCase {
    private let calendar = SleepCalendar.calendar(timeZone: "America/Los_Angeles")
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    func testNightRolloverKeepsMorningFragmentsWithThePreviousEvening() {
        XCTAssertEqual(SleepCalendar.nightDate(for: date(25, 5, 59), calendar: calendar), date(24, 0))
        XCTAssertEqual(SleepCalendar.nightDate(for: date(25, 6), calendar: calendar), date(24, 0))
        XCTAssertEqual(SleepCalendar.nightDate(for: date(25, 11, 59), calendar: calendar), date(24, 0))
    }
    func testNoonStartsANewNight() {
        XCTAssertEqual(SleepCalendar.nightDate(for: date(25, 12), calendar: calendar), date(25, 0))
    }
    func testNightTotalsIncludeNapsButVitalsUseMainRecordAndChosenSide() {
        let records = [SleepRecord(id: 1, side: "left", enteredBed: date(24, 22), leftBed: date(25, 6)),
                       SleepRecord(id: 2, side: "left", enteredBed: date(24, 15), leftBed: date(24, 16)),
                       SleepRecord(id: 3, side: "right", enteredBed: date(24, 22), leftBed: date(25, 7))]
        var wrong = VitalsRecord(id: 2, heartRate: 140, date: date(24, 23)); wrong.side = "right"
        let readings = [VitalsRecord(id: 1, heartRate: 60, date: date(24, 23)), wrong, VitalsRecord(id: 3, heartRate: 80, date: date(24, 15, 30))]
        let summary = SleepPeriodSummary.nights(days: [date(24, 0)], records: records, vitals: readings, side: .left, calendar: calendar)[0]
        XCTAssertEqual(summary.seconds, 9 * 3600); XCTAssertEqual(summary.main?.id, 1)
        XCTAssertEqual(summary.metrics[.heartRate]?.average, 60)
    }
    func testClockAverageCrossesMidnightAndDoesNotSubstituteMissingWake() {
        let average = SleepPeriodSummary.averageClock([date(24, 23), date(25, 1)], calendar: calendar)
        XCTAssertEqual(average.map { calendar.component(.hour, from: $0) }, 0)
        XCTAssertNil(SleepPeriodSummary.averageClock([], calendar: calendar))
        XCTAssertNil(SleepPeriodSummary.average([.nan, .infinity]))
    }
    func testMonthCellsUseCalendarWeekStartAndLeapYear() throws {
        let february = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 2, day: 12)))
        let days = SleepPeriodSummary.monthDays(containing: february, calendar: calendar)
        let cells = SleepPeriodSummary.monthCells(days: days, calendar: calendar)
        XCTAssertEqual(days.count, 29); XCTAssertEqual(cells.prefix(3).compactMap { $0 }.count, 0)
        XCTAssertEqual(cells[3], days[0]); XCTAssertEqual(cells.compactMap { $0 }, days)
    }
    func testStageSplitExcludesWakeAndMissingData() {
        let summary = SleepNightStageSummary(epochs: [
            .init(start: date(24, 22), duration: 120, stage: .wake, heartRate: .nan, hrv: nil, breathingRate: nil),
            .init(start: date(24, 23), duration: 300, stage: .deep, heartRate: .nan, hrv: nil, breathingRate: nil),
            .init(start: date(25, 1), duration: 900, stage: .light, heartRate: .nan, hrv: nil, breathingRate: nil)
        ], quality: nil, source: "Pod")
        XCTAssertEqual(summary.asleepSeconds, 1200); XCTAssertEqual(summary.fraction(.deep), 0.25)
        XCTAssertEqual(summary.fraction(.light), 0.75); XCTAssertEqual(summary.fraction(.rem), 0)
    }
    func testWeekStageFailuresKeepOtherNightsAndRejectWrongRecord() async {
        let model = SleepPeriodStageWorkspace()
        let records = (1...3).map { SleepRecord(id: $0, side: "left", enteredBed: date(20 + $0, 22), leftBed: date(21 + $0, 6)) }
        await model.load(records: records, side: .left) { _, identifier in
            if identifier == 1 { throw APIError.serverError(message: "Offline") }
            return PodSleepStages(blocks: [], sleepRecordId: identifier == 2 ? 99 : identifier, qualityScore: 70, stagedBy: .init(engine: "rules", version: nil))
        }
        XCTAssertEqual(model.errors.count, 2); XCTAssertEqual(model.summaries[3]?.quality, 70)
        XCTAssertNil(model.summaries[2]); XCTAssertFalse(model.loading)
        await model.load(records: [], side: .right) { _, _ in fatalError("No request expected") }
        XCTAssertTrue(model.summaries.isEmpty); XCTAssertTrue(model.errors.isEmpty)
    }
}
