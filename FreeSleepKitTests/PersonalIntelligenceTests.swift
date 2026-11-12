import Foundation
import CryptoKit
import Testing

@Test func localProvidersDoNotAccessKeychain() throws {
    #expect(try ProviderKeyStore.read(.apple).isEmpty)
    #expect(try ProviderKeyStore.read(.ollama).isEmpty)
}
import AIProxy
@testable import FreeSleepKit

struct PersonalIntelligenceTests {
    private let zone = TimeZone(identifier: "America/Los_Angeles")!
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func sample(_ from: String, _ through: String, source: String = "watch", stage: HistoricalSleepSample.Stage = .core) -> HistoricalSleepSample {
        .init(start: date(from), end: date(through), sourceID: source, sourceName: source, stage: stage)
    }
    @Test func overlappingRecordsAreMergedWithinOneSourceAndDifferentSourcesStaySeparate() throws {
        let history = HealthHistoryAnalyzer.build(samples: [
            sample("2026-10-14T05:00:00Z", "2026-10-14T09:00:00Z"),
            sample("2026-10-14T08:00:00Z", "2026-10-14T12:00:00Z"),
            sample("2026-10-14T05:00:00Z", "2026-10-14T12:00:00Z", source: "other"),
        ], now: date("2026-10-14T18:00:00Z"), timeZone: zone)
        #expect(history.sources.count == 2)
        #expect(history.sources.allSatisfy { $0.nights.count == 1 && $0.nights[0].asleepMinutes == 420 })
        #expect(history.sources.allSatisfy { $0.nights[0].deepMinutes == nil })
    }
    @Test func daylightSavingFallBackCountsActualElapsedSleep() throws {
        let history = HealthHistoryAnalyzer.build(samples: [sample("2026-11-01T07:00:00Z", "2026-11-01T16:00:00Z")],
            now: date("2026-11-01T20:00:00Z"), timeZone: zone)
        #expect(history.sources.first?.nights.first?.asleepMinutes == 540)
    }
    @Test func noonBoundarySplitsWithoutDroppingOrDuplicatingMinutes() throws {
        let history = HealthHistoryAnalyzer.build(samples: [sample("2026-10-14T18:00:00Z", "2026-10-14T20:00:00Z")],
            now: date("2026-10-14T21:00:00Z"), timeZone: zone)
        #expect(history.sources.first?.nights.count == 2)
        #expect(history.sources.first?.nights.map(\.asleepMinutes).reduce(0, +) == 120)
    }
    @Test func malformedOrFutureSamplesAreIgnoredAndMidnightTimingRemainsContinuous() {
        let history = HealthHistoryAnalyzer.build(samples: [sample("2026-10-14T20:00:00Z", "2026-10-14T19:00:00Z"),
            sample("2026-10-14T18:00:00Z", "2026-10-15T20:00:00Z")], now: date("2026-10-14T21:00:00Z"), timeZone: zone)
        #expect(history.sources.isEmpty); #expect(history.ignoredSamples == 2)
        let bedtime = HealthHistoryAnalyzer.median([HealthHistoryAnalyzer.bedtimeMinute(date("2026-10-14T06:50:00Z"), timeZone: zone),
            HealthHistoryAnalyzer.bedtimeMinute(date("2026-10-14T07:10:00Z"), timeZone: zone)])
        #expect(bedtime == 1440)
    }
    @Test func sparseHistoryDoesNotInventARecentTrendOrMissingVitals() {
        let now = date("2026-10-14T18:00:00Z")
        let history = HealthHistoryAnalyzer.build(samples: [sample("2026-10-14T05:00:00Z", "2026-10-14T12:00:00Z")], now: now, timeZone: zone)
        let facts = HealthHistoryAnalyzer.facts(source: history.sources.first, now: now, timeZone: zone)
        #expect(!facts.contains { $0.id == "health.change" || $0.id == "health.rhr" || $0.id == "health.timing" })
        #expect(facts.contains { $0.text.contains("Missing days are unknown") })
    }
    @Test func reportFactsKeepForwardCoverageForEveryNightOrder() throws {
        let now = date("2026-11-12T18:00:00Z")
        let history = HealthHistoryAnalyzer.build(samples: [
            sample("2026-10-31T05:00:00Z", "2026-10-31T13:00:00Z"),
            sample("2026-11-05T06:00:00Z", "2026-11-05T14:00:00Z"),
            sample("2026-11-10T06:00:00Z", "2026-11-10T14:00:00Z"),
        ], now: now, timeZone: zone)
        let source = try #require(history.sources.first)
        let expected = HealthHistoryAnalyzer.facts(source: source, now: now, timeZone: zone)
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            var reordered = source; reordered.nights = order.map { source.nights[$0] }
            #expect(HealthHistoryAnalyzer.facts(source: reordered, now: now, timeZone: zone) == expected)
        }
        #expect(expected.first?.id == "health.coverage")
        #expect(expected.first?.text.contains("3 noon-to-noon days") == true)
    }
    @Test func reportCoverageDatesUseTheSelectedHistoryTimeZone() throws {
        let now = date("2026-11-12T18:00:00Z")
        let start = date("2026-11-01T01:00:00Z"), end = date("2026-11-01T06:00:00Z")
        let source = HealthHistory.Source(id: "watch", name: "Watch", nights: [
            .init(id: "recorded-night", start: start, end: end, asleepMinutes: 300),
        ])
        let local = try #require(HealthHistoryAnalyzer.facts(source: source, now: now, timeZone: zone).first)
        let utc = try #require(HealthHistoryAnalyzer.facts(source: source, now: now, timeZone: TimeZone(secondsFromGMT: 0)!).first)
        var localDate = Date.FormatStyle(date: .abbreviated, time: .omitted); localDate.timeZone = zone
        let expectedDay = start.formatted(localDate)
        #expect(local.text.contains("\(expectedDay) through \(expectedDay)"))
        #expect(local.text != utc.text)
    }
    @Test func modelIDsRejectURLsQueriesAndTraversalButSupportLocalModelTags() {
        #expect(IntelligenceProvider.validModel("gemini-4-argon"))
        #expect(IntelligenceProvider.validModel("gemma3:4b"))
        #expect(!IntelligenceProvider.validModel("model?key=secret"))
        #expect(!IntelligenceProvider.validModel("../other"))
        #expect(!IntelligenceProvider.validModel(""))
    }
    @Test func providerErrorsNeverRepeatTheirPrivateResponseBody() {
        #expect(NativeModelClient.httpError(401).contains("key"))
        #expect(NativeModelClient.httpError(429).contains("billing"))
        #expect(!NativeModelClient.httpError(500).contains("secret"))
    }
    @Test func sdkRequestSupportsResponsesPrivacyAndCurrentModelIDs() throws {
        let request = OpenAICreateResponseRequestBody(input: .text("Synthetic test"), instructions: "Summarize",
            maxOutputTokens: 8000, model: "gpt-6-astra", store: false)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(json["store"] as? Bool == false); #expect(json["model"] as? String == "gpt-6-astra")
        #expect(json["max_output_tokens"] as? Int == 8000); #expect(json["tools"] == nil)
        let gemini = GeminiGenerateContentRequestBody(contents: [.init(parts: [.text("Synthetic test")])],
            generationConfig: .init(maxOutputTokens: 8000), systemInstruction: .init(parts: [.text("Summarize")]))
        let google = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(gemini)) as? [String: Any])
        #expect(google["tools"] == nil); #expect(google["contents"] != nil); #expect(google["systemInstruction"] != nil)
    }
    @Test func privateHistoryStoreRoundTripsAndClearingDoesNotLeaveReports() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let snapshots = PrivateSnapshotStore(directory: directory, namespace: "history-test", encryptionKey: { key })
        let store = PersonalIntelligenceStore(directory: directory, snapshots: snapshots)
        var archive = PersonalIntelligenceArchive()
        archive.reports = [.init(id: UUID(), createdAt: .now, provider: .apple, model: "Apple", source: "Synthetic", facts: [], text: "Fixture")]
        try store.write(archive)
        #expect(try store.read().reports.count == 1)
        let resources = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(resources.isExcludedFromBackup == true)
        try store.write(.init()); #expect(try store.read().reports.isEmpty)
    }
    @Test func promptLabelsPodOccupancyAndCannotContainAnAPIKeyByConstruction() {
        let text = PersonalReportPrompt.make(facts: [.init(id: "health.sleep", text: "Seven recorded days")], question: "What changed?")
        #expect(text.contains("[health.sleep]")); #expect(text.contains("What changed?"))
        #expect(PersonalReportPrompt.instructions.contains("Do not infer hot/cold from heart rate"))
    }
}
