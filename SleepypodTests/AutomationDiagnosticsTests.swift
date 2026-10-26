import XCTest
@testable import Sleepypod

final class AutomationDiagnosticsTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            let name: String
            let trigger: AutomationTrigger
            let enabled: Bool
            let rows: [AutomationDiagnostics.Run]
            let now: Double
            let startOfDay: Double
            let missing: [Double]
            let strip: AutomationEvaluationStripData
            let groups: [AutomationEvaluationGroup]
            let counts: [String: Int]
            let verdict: String?
        }
        struct Threshold: Decodable {
            struct Window: Decodable { let fn: String; let lastMin: Int }
            let signal: String; let op: String; let value: Double; let window: Window?
        }
        let synthetic: Bool
        let cases: [Case]
        let condition: AutomationCondition
        let thresholds: [Threshold]
    }
    func testSourceGeneratedMinuteSlotsMissingGraceGroupingAndOutcomeCounts() throws {
        let fixture = try fixture()
        XCTAssertTrue(fixture.synthetic)
        XCTAssertEqual(fixture.cases.count, 8)
        for example in fixture.cases {
            let log = AutomationEvaluationLog(runs: example.rows, trigger: example.trigger, now: example.now, startOfDay: example.startOfDay, expectMissing: example.enabled)
            XCTAssertEqual(log.strip, example.strip, example.name)
            XCTAssertEqual(log.missing, example.missing, example.name)
            XCTAssertEqual(log.groups, example.groups, example.name)
            XCTAssertEqual(log.verdict, example.verdict, example.name)
            for filter in AutomationEvaluationFilter.allCases { XCTAssertEqual(log.count(filter), example.counts[filter.rawValue], "\(example.name): \(filter)") }
            XCTAssertEqual(log.wouldCount, example.rows.filter { $0.outcome == "dry_run" }.count)
            XCTAssertEqual(log.firedCount, example.rows.filter { ["fired", "clamped"].contains($0.outcome) }.count)
            XCTAssertEqual(log.sentCount, example.rows.filter(\.sent).count)
        }
    }
    func testNestedThresholdsKeepWindowMeaningAndExcludeNonliteralComparisons() throws {
        let fixture = try fixture()
        let expected = fixture.thresholds.map { AutomationLiveThreshold(signal: $0.signal, operation: $0.op, value: $0.value, function: $0.window?.fn, minutes: $0.window?.lastMin) }
        XCTAssertEqual(AutomationLiveThreshold.collect(fixture.condition), expected)
        XCTAssertEqual(expected.count, 1)
        XCTAssertEqual(expected.first?.minutes, 10)
    }
    func testUnsortedRowsKeepTodaySeparateFromPriorDayAndExcludeInvalidFutureValues() {
        let today = 1_792_911_600_000.0
        let rows: [AutomationDiagnostics.Run] = [
            row(today + 120_000, "fired", sent: true), row(today - 60_000, "dry_run"),
            row(today + 60_000, "clamped"), row(today + 300_000, "fired", sent: true),
            .init(t: "not a date", outcome: "fired", reason: nil, sent: true), row(today, "unrecognized")
        ]
        let log = AutomationEvaluationLog(runs: rows, trigger: .init(), now: today + 180_000, startOfDay: today, expectMissing: false)
        XCTAssertEqual(log.unreadableCount, 3)
        XCTAssertEqual(log.firedCount, 2); XCTAssertEqual(log.sentCount, 1); XCTAssertEqual(log.wouldCount, 0)
        XCTAssertEqual(log.groups.first?.count, 2); XCTAssertEqual(log.groups.first?.firstMs, today + 60_000)
        XCTAssertEqual(log.groups.first?.lastMs, today + 120_000); XCTAssertNil(log.lastWould)
    }
    func testOldRowsInferOnlyTheRequestedWindowAndNeverBeforeFirstEvaluation() {
        let today = 1_792_911_600_000.0
        let old = row(today - 30 * 86_400_000, "skipped")
        let log = AutomationEvaluationLog(runs: [old], trigger: .init(), now: today + 120_000, startOfDay: today, expectMissing: true)
        XCTAssertEqual(log.missing, [today, today + 60_000])
        XCTAssertEqual(log.strip.ticks.count, 180)
        let empty = AutomationEvaluationLog(runs: [], trigger: .init(), now: today + 120_000, startOfDay: today, expectMissing: true)
        XCTAssertTrue(empty.missing.isEmpty); XCTAssertNil(empty.verdict)
    }
    private func row(_ milliseconds: Double, _ outcome: String, sent: Bool = false) -> AutomationDiagnostics.Run {
        .init(t: Date(timeIntervalSince1970: milliseconds / 1000).ISO8601Format(), outcome: outcome, reason: nil, sent: sent)
    }
    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "automation-diagnostics-fixtures", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
}
