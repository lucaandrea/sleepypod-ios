import XCTest
@testable import Sleepypod

@MainActor final class NightStageCoverageTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)
    private func epoch(_ start: Double, _ duration: Double, _ stage: SleepAnalyzer.SleepStage = .light) -> SleepAnalyzer.SleepEpoch {
        .init(start: base.addingTimeInterval(start), duration: duration, stage: stage, heartRate: 60, hrv: nil, breathingRate: nil)
    }
    func testBoundariesAndConflictingOverlapsRemainUnknown() {
        let windows = [DateInterval(start: base, duration: 100), DateInterval(start: base.addingTimeInterval(200), duration: 100)]
        let values = [epoch(-50, 200), epoch(25, 25, .deep), epoch(210, 200), epoch(210, 200)]
        let result = NightStageCoverage.epochs(values, within: windows)
        XCTAssertEqual(result.map { $0.start.timeIntervalSince(base) }, [0, 50, 210])
        XCTAssertEqual(result.map(\.duration), [25, 50, 90])
        XCTAssertEqual(result.reduce(0) { $0 + $1.duration }, 165)
        XCTAssertTrue(result.allSatisfy { $0.stage == .light })
    }
    func testInvalidEpochsNeverBecomeRecordedTime() {
        let result = NightStageCoverage.epochs([epoch(0, .nan), epoch(10, -1), epoch(.infinity, 50)],
            within: [DateInterval(start: base, duration: 100)])
        XCTAssertTrue(result.isEmpty)
    }
    func testWholeNightFetchesAllSegmentsAndClipsLegacyServerOverrun() async {
        let model = PodStageNightWorkspace()
        let records = [SleepRecord(id: 1, side: "left", enteredBed: base, leftBed: base.addingTimeInterval(100)),
                       SleepRecord(id: 2, side: "left", enteredBed: base.addingTimeInterval(200), leftBed: base.addingTimeInterval(300)),
                       SleepRecord(id: 3, side: "right", enteredBed: base, leftBed: base.addingTimeInterval(400))]
        let milliseconds = base.timeIntervalSince1970 * 1000
        await model.load(records: records, side: .left) { _, identifier in
            XCTAssertNotEqual(identifier, 3)
            return PodSleepStages(blocks: [.init(start: milliseconds, end: milliseconds + 500_000, stage: "light")], sleepRecordId: identifier)
        }
        XCTAssertEqual(model.results.count, 2); XCTAssertNil(model.result)
        XCTAssertEqual(model.epochs.reduce(0) { $0 + $1.duration }, 200)
        XCTAssertTrue(model.epochs.allSatisfy { $0.start < self.base.addingTimeInterval(100) || $0.start >= self.base.addingTimeInterval(200) })
    }
    func testFailureShowsPartialCoverageWithoutDiscardingSuccessfulSegment() async {
        let model = PodStageNightWorkspace()
        let records = (1...2).map { SleepRecord(id: $0, side: "left", enteredBed: base, leftBed: base.addingTimeInterval(100)) }
        let milliseconds = base.timeIntervalSince1970 * 1000
        await model.load(records: records, side: .left) { _, identifier in
            if identifier == 2 { throw URLError(.notConnectedToInternet) }
            return PodSleepStages(blocks: [.init(start: milliseconds, end: milliseconds + 100_000, stage: "light")], sleepRecordId: identifier)
        }
        XCTAssertEqual(model.results.count, 1); XCTAssertNil(model.result); XCTAssertNotNil(model.error)
        XCTAssertEqual(model.epochs.reduce(0) { $0 + $1.duration }, 100)
    }
}
