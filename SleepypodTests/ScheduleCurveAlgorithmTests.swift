import XCTest
@testable import Sleepypod

final class ScheduleCurveAlgorithmTests: XCTestCase {
    struct Fixture: Decodable {
        struct Example: Decodable {
            struct Input: Decodable { let intensity: String; let bedtimeMinutes: Int; let wakeMinutes: Int; let minTempF: Int; let maxTempF: Int }
            struct Point: Decodable { let minutesFromBedtime: Int; let tempOffset: Int; let phase: String }
            struct SetPoint: Decodable { let time: String; let temperature: Double }
            let input: Input; let points: [Point]; let temperatures: [String: Double]; let simplified: [SetPoint]
        }
        let examples: [Example]
    }
    func testPresetsMatchFifteenLiteralCoreExamples() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "temperature-core", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.examples.count, 15)
        for example in fixture.examples {
            let input = example.input
            let intensity = try XCTUnwrap(CoolingIntensity.allCases.first { $0.rawValue.lowercased() == input.intensity })
            let actual = ScheduleCurveAlgorithm.generate(bedtimeMinutes: input.bedtimeMinutes, wakeMinutes: input.wakeMinutes, intensity: intensity, minimum: input.minTempF, maximum: input.maxTempF)
            XCTAssertEqual(actual.map(\.minutesFromBedtime), example.points.map(\.minutesFromBedtime), "\(input)")
            XCTAssertEqual(actual.map(\.tempOffset), example.points.map(\.tempOffset), "\(input)")
            XCTAssertEqual(ScheduleCurveAlgorithm.temperatures(bedtimeMinutes: input.bedtimeMinutes, wakeMinutes: input.wakeMinutes, intensity: intensity, minimum: input.minTempF, maximum: input.maxTempF), example.temperatures)
            var draft = CurveDraft(); draft.bedtime = CurvePoint.clock(input.bedtimeMinutes); draft.wake = CurvePoint.clock(input.wakeMinutes)
            draft.coolest = input.minTempF; draft.warmest = input.maxTempF; draft.generate(intensity)
            XCTAssertEqual(draft.points.map(\.time), example.simplified.map(\.time))
            XCTAssertEqual(draft.points.map(\.temperature), example.simplified.map(\.temperature))
        }
    }
    func testSimplificationKeepsMidnightAndLongGapAnchors() {
        let points = ["20:00", "23:00", "00:00", "03:00", "08:00", "10:00"].map { CurvePoint(time: $0, temperature: 70) }
        let result = ScheduleCurveAlgorithm.simplify(points)
        XCTAssertTrue(result.contains { $0.time == "00:00" })
        XCTAssertEqual(CurvePoint.ordered(result).map(\.time), result.map(\.time))
    }
}
