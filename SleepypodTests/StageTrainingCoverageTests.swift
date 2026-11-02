import Foundation
import Testing
@testable import Sleepypod

@Suite("Complete-night training coverage")
struct StageTrainingCoverageTests {
    @Test func nightConfirmationChangesWithSignalsLabelsAndContract() {
        let start = Date(timeIntervalSince1970: 1_793_333_700)
        let first = StageDataset.Night(id: 1, enteredBed: start, leftBed: start.addingTimeInterval(8 * 3600),
            watch: [.init(start: start, end: start.addingTimeInterval(300), stage: .light)],
            rows: [.init(start: start, values: ["heartRate": 60], label: .light)], rules: [], challenger: [], recordIDs: [1])
        var changed = first
        changed.recordIDs = [2]
        #expect(first.reviewToken(contract: .challenger) != nil)
        #expect(first.reviewToken(contract: .challenger) == first.reviewToken(contract: .challenger))
        #expect(first.reviewToken(contract: .challenger) != changed.reviewToken(contract: .challenger))
        let changedSignals = StageDataset.Night(id: 1, enteredBed: first.enteredBed, leftBed: first.leftBed, watch: first.watch,
            rows: [.init(start: start, values: ["heartRate": 61], label: .light)], rules: [], challenger: [], recordIDs: [1])
        #expect(first.reviewToken(contract: .challenger) != changedSignals.reviewToken(contract: .challenger))
    }
    private let start = Date(timeIntervalSince1970: 1_793_337_458)
    private var window: DateInterval { DateInterval(start: start, duration: 8 * 3600) }
    private func interval(_ from: Double, _ to: Double) -> DateInterval {
        DateInterval(start: start.addingTimeInterval(from * 3600), end: start.addingTimeInterval(to * 3600))
    }
    private func record(_ id: Int, from: Double, to: Double?) -> SleepRecord {
        var record = SleepRecord(id: id, side: "left", enteredBed: start.addingTimeInterval(from * 3600),
                                 leftBed: to.map { start.addingTimeInterval($0 * 3600) })
        if let to { record.presentIntervals = "[[\(start.timeIntervalSince1970 + from * 3600),\(start.timeIntervalSince1970 + to * 3600)]]" }
        return record
    }

    @Test func fullCoveragePassesAndDuplicateWindowsCountOnce() {
        #expect(StageTrainingCoverage.issue([window], within: window) == nil)
        #expect(StageTrainingCoverage.issue([interval(0, 4), interval(0, 4)], within: window) != nil)
        #expect(StageTrainingCoverage.merged([window, window], within: window).count == 1)
    }

    @Test func partialWatchNightAndLateStartFailEvenWithManySamples() {
        let tail = (0..<240).map { _ in interval(4, 8) }
        #expect(StageTrainingCoverage.issue(tail, within: window) != nil)
        #expect(StageTrainingCoverage.issue([interval(0.6, 8)], within: window) == "A gap exceeds 30 minutes")
    }

    @Test func briefBathroomGapIsAllowedButLongUnobservedGapIsNot() {
        #expect(StageTrainingCoverage.issue([interval(0, 4), interval(4.1, 8)], within: window) == nil)
        #expect(StageTrainingCoverage.issue([interval(0, 4), interval(4.6, 8)], within: window) == "A gap exceeds 30 minutes")
    }

    @Test func observationsOutsideNightDoNotPadItsCoverage() {
        #expect(StageTrainingCoverage.issue([interval(-10, 2), interval(7, 20)], within: window) != nil)
        #expect(StageTrainingCoverage.issue([], within: window) == "No coverage")
    }

    @Test func completedBoundsDoNotReplaceMissingPresence() {
        var value = record(1, from: 0, to: 8)
        value.presentIntervals = "[[\(start.timeIntervalSince1970),\(start.timeIntervalSince1970 + 3 * 3600)]]"
        let night = StageTrainingNight(records: [value], date: start)
        #expect(night.issue(now: start.addingTimeInterval(10 * 3600))?.contains("90%") == true)
        value.presentIntervals = nil
        #expect(StageTrainingNight(records: [value], date: start).issue(now: .distantFuture)?.contains("missing") == true)
    }

    @Test func ongoingShortLongAndFutureRecordingsAreExcluded() {
        for value in [record(1, from: 0, to: nil), record(2, from: 0, to: 3), record(3, from: 0, to: 16), record(4, from: 0, to: 8)] {
            #expect(StageTrainingNight(records: [value], date: start).issue(now: start.addingTimeInterval(7 * 3600)) != nil)
        }
    }

    @Test func nighttimeFragmentsUsePodTimezoneAcrossDaylightSaving() throws {
        let calendar = SleepCalendar.calendar(timeZone: "America/Los_Angeles")
        let before = try #require(ISO8601DateFormatter().date(from: "2026-11-01T05:30:00Z"))
        let after = try #require(ISO8601DateFormatter().date(from: "2026-11-01T10:30:00Z"))
        let first = SleepRecord(id: 1, side: "left", enteredBed: before, leftBed: after)
        let second = SleepRecord(id: 2, side: "left", enteredBed: after.addingTimeInterval(120), leftBed: after.addingTimeInterval(4 * 3600))
        let nights = StageTrainingNight.grouped([second, first, first], calendar: calendar)
        #expect(nights.count == 1)
        #expect(nights[0].records.map(\.id) == [1, 2])
        #expect(calendar.component(.day, from: nights[0].date) == 31)
    }

    @Test func overlappingRecordsAcrossNoonCannotLeakIntoDifferentFolds() {
        let first = record(1, from: 0, to: 16)
        let second = record(2, from: 15, to: 20)
        let nights = StageTrainingNight.grouped([first, second], calendar: SleepCalendar.calendar(timeZone: "America/Los_Angeles"))
        #expect(nights.count == 1)
        #expect(nights[0].issue(now: .distantFuture) != nil)
    }

    @Test func conflictingWatchStagesAreNotResolvedByInputOrder() {
        let first = WatchComparison.StageSample(start: window.start, end: window.end, stage: .light)
        let second = WatchComparison.StageSample(start: interval(4, 5).start, end: interval(4, 5).end, stage: .deep)
        #expect(StageTrainingCoverage.hasConflictingStages([first, second]))
        #expect(StageTrainingCoverage.hasConflictingStages([second, first]))
        #expect(!StageTrainingCoverage.hasConflictingStages([first, first]))
    }
}
