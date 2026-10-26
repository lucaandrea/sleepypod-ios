import XCTest
@testable import Sleepypod

final class CurveChartProjectionTests: XCTestCase {
    private var points: [CurvePoint] { [.init(time: "22:00", temperature: 74), .init(time: "02:00", temperature: 68), .init(time: "07:00", temperature: 80)] }
    func testOvernightDomainAndDragMatchFifteenMinuteWholeDegreeContract() {
        let points = points, projection = CurveChartProjection(points: points)
        XCTAssertTrue(projection.overnight); XCTAssertEqual(projection.start, 1200); XCTAssertEqual(projection.end, 1920)
        XCTAssertEqual(projection.low, 64); XCTAssertEqual(projection.high, 84)
        XCTAssertEqual(projection.minute(points[1]), 1560)
        let moved = projection.moved(points[1], horizontal: (1577 - 1200) / 720.0, vertical: 0.37)
        XCTAssertEqual(moved.time, "02:15"); XCTAssertEqual(moved.temperature, 77); XCTAssertEqual(moved.id, points[1].id)
        XCTAssertEqual(projection.horizontal(points[0]), 1 / 6.0, accuracy: 0.0001)
    }
    func testDraggingClampsCoordinatesAndHardwareLimitsAndRejectsNonfiniteInput() {
        let point = CurvePoint(time: "10:00", temperature: 55), warm = CurvePoint(time: "14:00", temperature: 110)
        let projection = CurveChartProjection(points: [point, warm])
        XCTAssertFalse(projection.overnight)
        XCTAssertEqual(projection.moved(point, horizontal: -1, vertical: 2).temperature, 55)
        XCTAssertEqual(projection.moved(point, horizontal: 2, vertical: -1).temperature, 110)
        XCTAssertEqual(projection.moved(point, horizontal: .nan, vertical: 0), point)
        XCTAssertEqual(projection.moved(point, horizontal: 0, vertical: .infinity), point)
    }
    func testCrossingAnotherPointPreservesBothIdentitiesAndSaveRejectsDuplicateTime() {
        var draft = CurveDraft(); draft.name = "Overnight"; draft.points = points
        let projection = CurveChartProjection(points: draft.points)
        let first = draft.points[0].id, second = draft.points[1].id
        draft.points[0] = projection.moved(draft.points[0], horizontal: projection.horizontal(draft.points[1]), vertical: 0.5)
        XCTAssertEqual(draft.points.count, 3); XCTAssertEqual(draft.points[0].id, first); XCTAssertEqual(draft.points[1].id, second)
        XCTAssertEqual(draft.validation, "Each set point needs a different time.")
    }
}
