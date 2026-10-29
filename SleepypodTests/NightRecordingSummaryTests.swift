import XCTest
@testable import Sleepypod

final class NightRecordingSummaryTests: XCTestCase {
    func testFragmentsAndOverlapsDoNotLoseHoursOrInventSleepInGaps() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        func record(_ identifier: Int, _ from: Double, _ until: Double) -> SleepRecord {
            .init(id: identifier, side: "left", enteredBed: start.addingTimeInterval(from * 3600), leftBed: start.addingTimeInterval(until * 3600))
        }
        let summary = NightRecordingSummary(records: [record(1, 0, 3), record(2, 3.5, 6.5), record(3, 8.5, 9.5), record(4, 1, 2)])
        XCTAssertEqual(summary.recordedSeconds, 7 * 3600)
        XCTAssertEqual(summary.gapSeconds, 9_000)
        XCTAssertEqual(summary.start, start)
        XCTAssertEqual(summary.end, start.addingTimeInterval(9.5 * 3600))
        XCTAssertEqual(summary.recordCount, 4)
    }
    func testOpenAndInvalidRecordsDoNotExtrapolateToThePresent() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let summary = NightRecordingSummary(records: [
            .init(id: 1, side: "left", enteredBed: start, leftBed: nil),
            .init(id: 2, side: "left", enteredBed: start, leftBed: start.addingTimeInterval(-60))
        ])
        XCTAssertEqual(summary.recordedSeconds, 0)
        XCTAssertEqual(summary.gapSeconds, 0)
        XCTAssertTrue(summary.ongoing)
        XCTAssertNil(summary.start)
    }
}
