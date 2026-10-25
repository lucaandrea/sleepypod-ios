import Foundation
import Testing
@testable import FreeSleepKit

private final class CoverageResources: NSObject {}

struct DataCoverageTests {
    private struct Fixture: Decodable { var name: String; var analytics: SleepAnalytics; var coaching: Coaching }
    private func fixtures() throws -> [Fixture] {
        let url = try #require(Bundle(for: CoverageResources.self).url(forResource: "coverage-cases", withExtension: "json"))
        return try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
    }
    @Test func nativeDemoMatchesServerForSparseUnknownDSTAndLeapDayRecords() throws {
        let cases = try fixtures()
        #expect(cases.count == 7)
        for fixture in cases {
            let expected = fixture.analytics
            let computed = DemoSleepSummary.analytics(expected.episodes ?? [], timeZone: expected.timeZone)
            #expect(computed == expected, "Coverage and summary drift in \(fixture.name)")
        }
        let sparse = try #require(cases.first { $0.name == "below-threshold" }?.analytics)
        #expect(sparse.summary.weeklyChangeMinutes == nil)
        #expect(sparse.quality?.coverage?.previous?.presenceNights == 2)
        let enough = try #require(cases.first { $0.name == "at-threshold" }?.analytics)
        #expect(enough.summary.weeklyChangeMinutes == 120)
        #expect(enough.quality?.coverage?.comparisonAvailable == true)
    }
    @Test func olderServersStillDecodeWithoutCoverageAndLabelsRemainExplicit() throws {
        let original = try #require(fixtures().last?.analytics)
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        payload.removeValue(forKey: "quality")
        let legacy = try JSONDecoder().decode(SleepAnalytics.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(legacy.quality == nil)
        #expect(legacy.nights == original.nights)
        #expect(DataCoverage.Day(date: "2026-10-14", status: "unknown").label == "Presence unknown")
        #expect(DataCoverage.Day(date: "2026-10-14", status: "not_returned").label == "No record returned")
        #expect(DataCoverage.Day(date: "2026-10-14", status: "future-status").label == "Coverage unknown")
    }
    @Test func localCoachNamesTheRecordedPeriodAndExplainsUnavailableComparisons() throws {
        let sparse = try #require(fixtures().first { $0.name == "below-threshold" }?.analytics)
        let coaching = DemoSleepSummary.coaching(sparse, provider: "rules")
        #expect(coaching.observations.contains { $0.contains("recorded period ending 2026-10-14") })
        #expect(!coaching.observations.contains { $0.contains("changed by") })
        #expect(coaching.limitations.contains { $0.contains("at least 3 nights") })
    }
    @Test func nativeReceiptsMatchServerForAllCalendarAndMissingDataCases() throws {
        for fixture in try fixtures() {
            let computed = DemoSleepSummary.coaching(fixture.analytics, provider: "rules")
            #expect(computed.grounding == fixture.coaching.grounding, "Receipt drift in \(fixture.name)")
            #expect(computed.grounding?.facts.map(\.observation) == computed.observations)
            #expect(computed.limitations == fixture.coaching.limitations)
        }
    }
    @Test func olderCoachingStillDecodesWithoutClaimingReceiptsExist() throws {
        let original = try #require(fixtures().last?.coaching)
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        payload.removeValue(forKey: "grounding")
        let legacy = try JSONDecoder().decode(Coaching.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(legacy.grounding == nil)
        #expect(legacy.observations == original.observations)
    }
}
