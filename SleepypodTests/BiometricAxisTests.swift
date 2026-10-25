import XCTest
@testable import Sleepypod

@MainActor final class BiometricAxisTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_790_000_000)
    private func time(_ hours: Double) -> Date { origin.addingTimeInterval(hours * 3600) }

    func testCompressedAxisPreservesSessionTimesAndSnapsEmptyGaps() throws {
        let axis = BiometricTimeAxis(intervals: [time(0)...time(2), time(24)...time(26)], window: time(0)...time(48), collapse: true)
        XCTAssertTrue(axis.collapsed)
        XCTAssertEqual(axis.segments.count, 2)
        XCTAssertEqual(axis.position(time(2)), 0.47, accuracy: 0.000001)
        XCTAssertEqual(axis.position(time(24)), 0.53, accuracy: 0.000001)
        for hour in [0.0, 0.5, 1.8, 2.0, 24.0, 25.2, 26.0] {
            XCTAssertEqual(try XCTUnwrap(axis.date(at: axis.position(time(hour)))).timeIntervalSince1970,
                           time(hour).timeIntervalSince1970, accuracy: 0.000001)
        }
        XCTAssertEqual(axis.date(at: 0.48), time(2))
        XCTAssertEqual(axis.date(at: 0.52), time(24))
        XCTAssertNil(axis.segmentIndex(containing: time(12)))
        XCTAssertEqual(axis.segmentIndex(containing: time(25)), 1)
        XCTAssertNil(axis.date(at: .nan)); XCTAssertNil(axis.date(at: .infinity))
        XCTAssertEqual(axis.date(at: -1), time(0)); XCTAssertEqual(axis.date(at: 2), time(26))
    }

    func testAxisClipsOverlapsAndExpandsRealElapsedTime() throws {
        let intervals = [time(-4)...time(4), time(2)...time(8), time(20)...time(40)]
        let axis = BiometricTimeAxis(intervals: intervals, window: time(0)...time(24), collapse: true)
        XCTAssertEqual(axis.segments.map(\.dates), [time(0)...time(8), time(20)...time(24)])
        let expanded = BiometricTimeAxis(intervals: intervals, window: time(0)...time(24), collapse: false)
        XCTAssertFalse(expanded.collapsed); XCTAssertTrue(expanded.breaks.isEmpty)
        XCTAssertEqual(expanded.position(time(6)), 0.25)
        XCTAssertEqual(expanded.date(at: 0.75), time(18))
        let empty = BiometricTimeAxis(intervals: [], window: time(0)...time(24), collapse: true)
        XCTAssertEqual(empty.date(at: 0.5), time(12))
    }

    func testManyGapsNeverConsumeMoreThanTwentyPercentOfPlot() {
        let intervals = (0..<40).map { time(Double($0 * 24))...time(Double($0 * 24 + 8)) }
        let axis = BiometricTimeAxis(intervals: intervals, window: time(0)...time(1000), collapse: true)
        XCTAssertEqual(axis.breaks.count, 39)
        XCTAssertEqual(axis.segments.reduce(0) { $0 + $1.upper - $1.lower }, 0.8, accuracy: 0.000001)
        XCTAssertEqual(axis.segments.last?.upper ?? 0, 1, accuracy: 0.000001)
    }

    func testSampleIntervalsSplitByTimestampGapNotBucketWidth() {
        let intervals = BiometricTimeAxis.intervals(dates: [time(2), time(0.5), time(0), time(1.01)], sampleDuration: 300)
        XCTAssertEqual(intervals.count, 3)
        XCTAssertEqual(intervals[0], time(0)...time(0.5).addingTimeInterval(300))
        XCTAssertEqual(intervals[1].lowerBound, time(1.01))
        XCTAssertEqual(BiometricTimeAxis.intervals(dates: [origin], sampleDuration: -.infinity).first?.upperBound, origin.addingTimeInterval(60))
    }

    func testSessionsSeparateGapsMethodsAndHRVDefinitions() throws {
        var records = (0..<6).map { VitalsRecord(id: $0, heartRate: Double(60 + $0), hrv: 30, date: time($0 < 4 ? Double($0) / 60 : Double($0 - 1))) }
        records[2].processingRunId = "new"; records[3].processingRunId = "new"
        records[3].provenance = VitalProvenance(interpretation: "original_observation", status: "recorded", processingRunId: "new", configurationHash: "hash", hrvMetricId: "hrv_sdnn")
        let invalid = VitalsRecord(id: 99, heartRate: .nan, hrv: .infinity, breathingRate: nil, date: time(2))
        let sessions = BiometricSession.split(Array(records.reversed()) + [invalid])
        XCTAssertEqual(sessions.map { $0.records.map(\.id) }, [[0, 1], [2], [3], [4], [5]])
        XCTAssertEqual(try XCTUnwrap(sessions[0].stats[.heartRate]).average, 60.5)
        XCTAssertEqual(sessions[1].interval.upperBound.timeIntervalSince(sessions[1].start), 60)
        XCTAssertEqual(Set(sessions.map(\.id)).count, sessions.count)
    }

    func testMappedNavigationUsesVisibleSessionsAndHonorsBounds() {
        var viewport = BiometricViewport(start: time(0), end: time(96))
        let intervals = (0..<4).map { time(Double($0 * 24))...time(Double($0 * 24 + 8)) }
        let axis = BiometricTimeAxis(intervals: intervals, window: viewport.full, collapse: true)
        viewport.scale(2, anchor: time(4), using: axis)
        XCTAssertEqual(viewport.window.lowerBound, time(0))
        XCTAssertEqual(viewport.zoom(using: axis), 2, accuracy: 0.001)
        viewport.pan(100, using: axis)
        XCTAssertEqual(viewport.window.upperBound, time(80))
        viewport.pan(-100, using: axis)
        XCTAssertEqual(viewport.window.lowerBound, time(0))
        viewport.scale(.nan, using: axis)
        XCTAssertEqual(viewport.window.lowerBound, time(0))
        viewport.focus(time(24)...time(32)); XCTAssertEqual(viewport.window, time(24)...time(32))
        viewport.focus(time(24)...time(24.1))
        let focusedZoom = viewport.zoom(using: axis)
        let focusedWindow = viewport.window
        viewport.scale(1.5, using: axis)
        XCTAssertEqual(viewport.window, focusedWindow)
        viewport.scale(0.5, using: axis)
        XCTAssertEqual(viewport.zoom(using: axis), focusedZoom / 2, accuracy: 0.001)
        viewport.reset(); XCTAssertEqual(viewport.window, viewport.full)
    }
}
