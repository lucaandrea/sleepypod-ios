import XCTest
@testable import Sleepypod

final class ControlPracticeTests: XCTestCase {
    func testTemperatureTapImmediatelyChangesTheRequestedExample() {
        var example = ControlPractice()
        XCTAssertFalse(example.completed(.temperature))
        example.send(.step(-1)); XCTAssertEqual(example.requestedTargetF, 75)
        XCTAssertTrue(example.completed(.temperature))
        example.send(.step(1)); XCTAssertEqual(example.requestedTargetF, 76)
        XCTAssertTrue(example.completed(.temperature))
    }
    func testTemperatureStepsAreBoundedAndRejectArbitraryOffsets() {
        var example = ControlPractice(); example.send(.step(Int.max)); XCTAssertEqual(example.requestedTargetF, 76)
        XCTAssertFalse(example.completed(.temperature))
        for _ in 0..<40 { example.send(.step(-1)) }; XCTAssertEqual(example.requestedTargetF, 65)
        for _ in 0..<40 { example.send(.step(1)) }; XCTAssertEqual(example.requestedTargetF, 90)
    }
    func testWakeNeedsExactReviewAndEditingWithdrawsEarlierReview() {
        var example = ControlPractice(); example.send(.saveWake); XCTAssertEqual(example.savedWake, "07:00")
        example.send(.reviewWake); XCTAssertEqual(example.reviewedWake, "08:00")
        example.send(.editWake("09:00")); XCTAssertNil(example.reviewedWake)
        example.send(.saveWake); XCTAssertEqual(example.savedWake, "07:00")
        example.send(.reviewWake); example.send(.saveWake)
        XCTAssertEqual(example.savedWake, "09:00"); XCTAssertTrue(example.completed(.wake)); XCTAssertNil(example.reviewedWake)
    }
    func testInvalidTimesCannotBeReviewedOrSaved() {
        for time in ["", "7:00", "24:00", "00:60", "-1:30", "08:00\n", "０８:００", "08:00:00", " 08:00"] {
            var example = ControlPractice(); example.send(.editWake(time)); example.send(.reviewWake); example.send(.saveWake)
            XCTAssertNil(example.reviewedWake); XCTAssertEqual(example.savedWake, "07:00"); XCTAssertNil(ControlPractice.warmingTime(time))
        }
    }
    func testWarmingWrapsMidnightWithNoDateOrTimezoneDependency() {
        for (wake, warming) in [("00:00", "23:30"), ("00:15", "23:45"), ("00:30", "00:00"), ("07:00", "06:30"), ("23:59", "23:29")] {
            XCTAssertEqual(ControlPractice.warmingTime(wake), warming)
        }
    }
    func testStopsAreIndependentAndKeepNextAlarm() {
        var example = ControlPractice(); example.send(.reviewWake); example.send(.saveWake)
        example.send(.stopTemperature); XCTAssertFalse(example.temperatureOn); XCTAssertTrue(example.vibrationOn)
        XCTAssertFalse(example.completed(.stop)); example.send(.stopVibration)
        XCTAssertTrue(example.completed(.stop)); XCTAssertEqual(example.savedWake, "08:00")
    }
    func testSkippingIsNotCompletionAndResetDiscardsEverything() {
        var example = ControlPractice(); example.send(.lesson(.stop)); XCTAssertEqual(example.completedCount, 0)
        example.send(.stopTemperature); example.send(.stopVibration); XCTAssertEqual(example.completedCount, 1)
        example.send(.reset); XCTAssertEqual(example, ControlPractice())
    }
    func testAllThreeRequireTheirActionsAndAreIndependentOfLessonSelection() {
        var example = ControlPractice(); example.send(.step(-1))
        example.send(.reviewWake); example.send(.saveWake); example.send(.stopTemperature); example.send(.stopVibration)
        XCTAssertEqual(example.completedCount, 3); example.send(.lesson(.wake)); XCTAssertEqual(example.completedCount, 3)
    }
}
