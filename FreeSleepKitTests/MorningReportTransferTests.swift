import Foundation
import Testing
@testable import FreeSleepKit

private final class MorningReportFixtureBundle: NSObject {}

struct MorningReportTransferTests {
    private func date(_ text: String) throws -> Date { try #require(ISO8601DateFormatter().date(from: text)) }
    private func example() throws -> PersonalSleepReport {
        let dates = ["2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23", "2026-10-24",
                     "2026-10-25", "2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30",
                     "2026-10-31", "2026-11-01", "2026-11-02"]
        let boundaries = try dates.map { try date("\($0)T\($0 >= "2026-11-01" ? "20" : "19"):00:00Z") }
        let comparison = ReportSleepComparison(sourceID: "synthetic-watch", sourceName: "Synthetic Watch",
            timeZone: "America/Los_Angeles", importedAt: try date("2026-11-02T16:00:00Z"), asOf: try date("2026-11-02T16:01:00Z"),
            days: (0..<14).map { .init(start: boundaries[$0], end: boundaries[$0 + 1], minutes: $0 == 0 ? nil : $0 < 7 ? 420 : 480) }, omittedRecords: 0)
        return PersonalSleepReport(id: try #require(UUID(uuidString: "120c83db-50f9-4fef-879d-5dc603978bea")),
            createdAt: try date("2026-11-02T16:05:00Z"), provider: .apple, model: "fixture-local-model", source: "Synthetic Watch",
            facts: [.init(id: "health.sleep", text: "Synthetic source-specific sleep estimates; completeness is unknown.")],
            text: "### Recorded coverage\nThese fixture observations do not prove a sleep improvement. [health.sleep]",
            comparison: comparison, followUps: [.init(id: try #require(UUID(uuidString: "8893f3e4-0eef-4eb5-a53f-f273574c55de")),
                createdAt: try date("2026-11-02T16:06:00Z"), question: "How complete are these observations?",
                text: "Unknown days remain gaps.", provider: .apple, model: "fixture-local-model")])
    }

    @Test func exportedDocumentMatchesTheWebContractFixture() throws {
        let report = try example(), now = try date("2026-11-02T16:07:00Z")
        let exported = try MorningReportTransfer.document(report, now: now)
        let fixtureURL = try #require(Bundle(for: MorningReportFixtureBundle.self).url(forResource: "morning-report-v1", withExtension: "json"))
        let actual = try #require(JSONSerialization.jsonObject(with: exported) as? NSDictionary)
        let expected = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? NSDictionary)
        #expect(actual == expected)
        let comparison = try #require(report.comparison)
        #expect(comparison.isValid)
        #expect(comparison.days[12].end.timeIntervalSince(comparison.days[12].start) == 25 * 3600)
    }

    @Test func exportDoesNotChangeThePrivateArchiveOrInventAChartForLegacyReports() throws {
        var report = try example(); report.comparison = nil; report.followUps = nil
        let before = try JSONEncoder().encode(report)
        let exported = try MorningReportTransfer.document(report, now: date("2026-11-02T16:07:00Z"))
        let container = try #require(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        let object = try #require(container["report"] as? [String: Any])
        #expect(object["createdAt"] as? Int64 == 1_793_635_500_000)
        #expect(object["comparison"] == nil); #expect(object["followUps"] == nil)
        #expect(Set(object.keys) == Set(["id", "createdAt", "provider", "model", "source", "facts", "text"]))
        #expect(try JSONDecoder().decode(PersonalSleepReport.self, from: before) == report)
    }

    @Test(arguments: ["future", "duplicate-fact", "early-answer", "duplicate-answer", "negative-tokens", "long-model", "invalid-clock"])
    func rejectsInvalidReportBeforeAnyUpload(kind: String) throws {
        var report = try example()
        let now = try date("2026-11-02T16:07:00Z")
        switch kind {
        case "future": report.createdAt = now.addingTimeInterval(1)
        case "duplicate-fact": report.facts.append(report.facts[0])
        case "early-answer": report.followUps?[0].createdAt = report.createdAt.addingTimeInterval(-1)
        case "duplicate-answer": report.followUps?[0].id = report.id
        case "negative-tokens": report.inputTokens = -1
        case "long-model": report.model = String(repeating: "x", count: 129)
        default: report.createdAt = Date(timeIntervalSince1970: .nan)
        }
        #expect(throws: MorningReportTransfer.Failure.self) { try MorningReportTransfer.document(report, now: now) }
    }

    @Test func boundsTheCompleteUTF8DocumentAndFloorsFractionalMilliseconds() throws {
        var report = try example()
        report.createdAt.addTimeInterval(0.0009)
        let now = try date("2026-11-02T16:07:00Z")
        let container = try #require(JSONSerialization.jsonObject(with: MorningReportTransfer.document(report, now: now)) as? [String: Any])
        let object = try #require(container["report"] as? [String: Any])
        #expect(object["createdAt"] as? Int64 == 1_793_635_500_000)
        report.facts = (0..<80).map { .init(id: "health.example\($0)", text: String(repeating: "x", count: 8000)) }
        #expect(throws: MorningReportTransfer.Failure.tooLarge) { try MorningReportTransfer.document(report, now: now) }
    }
}
