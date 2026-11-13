import CryptoKit
import Foundation
import Testing
@testable import FreeSleepKit

struct MorningBriefTests {
    private let zone = TimeZone(identifier: "America/Los_Angeles")!
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func history(_ nights: [HealthHistory.Night], now: Date) -> HealthHistory {
        .init(importedAt: now, timeZone: zone.identifier, sources: [.init(id: "watch", name: "Watch", nights: nights)], ignoredSamples: 0)
    }
    private func night(_ start: String, _ end: String, minutes: Double) -> HealthHistory.Night {
        .init(id: start, start: date(start), end: date(end), asleepMinutes: minutes)
    }
    @MainActor @Test func personalExampleContainsTwelveComparableNightsAtEveryHourAndAcrossDST() throws {
        let identity = PersonalHealthIdentity(podID: UUID(), householdID: UUID(), accountID: UUID(), sleeperID: UUID())
        for anchor in ["2026-03-09T00:00:00Z", "2026-11-02T00:00:00Z", "2026-11-13T00:00:00Z"] {
            for hour in 0..<24 {
                let now = date(anchor).addingTimeInterval(Double(hour) * 3600)
                let evidence = PersonalAccountReportsExample.evidence(identity: identity, now: now)
                let comparison = try #require(evidence.comparison)
                #expect(comparison.isValid)
                #expect(comparison.observedCount == 12, "Example lost nights at \(now)")
                #expect(comparison.omittedRecords == 0)
                #expect(comparison.priorValues.count >= 4 && comparison.recentValues.count >= 4)
                #expect(comparison.medianChange != nil)
            }
        }
    }
    @Test func frozenComparisonPreservesDSTAndMissingDaysWithoutFillingZero() throws {
        let now = date("2026-11-02T17:00:00Z")
        let archive = history([night("2026-11-01T05:00:00Z", "2026-11-01T16:00:00Z", minutes: 500)], now: now)
        let comparison = try #require(ReportSleepComparison.capture(source: archive.sources.first, history: archive, now: now))
        #expect(comparison.isValid); #expect(comparison.days.count == 14)
        #expect(comparison.observedCount == 1); #expect(comparison.days.filter { $0.minutes == nil }.count == 13)
        #expect(comparison.days.contains { $0.end.timeIntervalSince($0.start) == 25 * 3600 })
        #expect(comparison.latest?.minutes == 500); #expect(comparison.medianChange == nil)
        var tampered = comparison; tampered.days[0].minutes = 0
        #expect(!tampered.isValid)
        tampered = comparison; tampered.days[0].end.addTimeInterval(3600)
        #expect(!tampered.isValid)
    }
    @Test func duplicateAndConflictingBucketsCannotDoubleCountOrInventACompleteNight() throws {
        let now = date("2026-11-02T17:00:00Z")
        let one = night("2026-11-02T07:00:00Z", "2026-11-02T15:00:00Z", minutes: 400)
        var archive = history([one, one], now: now)
        var comparison = try #require(ReportSleepComparison.capture(source: archive.sources.first, history: archive, now: now))
        #expect(comparison.observedCount == 1)
        var other = one; other.asleepMinutes = 410
        archive.sources[0].nights.append(other)
        comparison = try #require(ReportSleepComparison.capture(source: archive.sources.first, history: archive, now: now))
        #expect(comparison.observedCount == 0); #expect(comparison.omittedRecords == 3)
    }
    @Test func futureUnimportedImpossibleAndOutOfRangeRecordsRemainUnavailable() throws {
        let now = date("2026-11-02T17:00:00Z")
        let archive = history([
            night("2026-11-02T16:00:00Z", "2026-11-02T18:00:00Z", minutes: 60),
            night("2026-11-01T05:00:00Z", "2026-11-01T06:00:00Z", minutes: 500),
            night("2026-10-01T05:00:00Z", "2026-10-01T12:00:00Z", minutes: 400)
        ], now: now)
        let comparison = try #require(ReportSleepComparison.capture(source: archive.sources.first, history: archive, now: now))
        #expect(comparison.observedCount == 0); #expect(comparison.medianChange == nil)
        var future = archive; future.importedAt.addTimeInterval(1)
        #expect(ReportSleepComparison.capture(source: archive.sources.first, history: future, now: now) == nil)
        future = archive; future.timeZone = "invalid"
        #expect(ReportSleepComparison.capture(source: archive.sources.first, history: future, now: now) == nil)
    }
    @Test func comparisonUsesOneSourceAndRequiresFourObservedDaysPerPeriod() throws {
        let now = date("2026-11-02T17:00:00Z")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let current = HealthHistoryAnalyzer.bucket(for: now, calendar: calendar)
        let nights = (-13...0).map { offset -> HealthHistory.Night in
            let bucket = calendar.date(byAdding: .day, value: offset, to: current)!
            let start = bucket.addingTimeInterval(10 * 3600)
            return .init(id: bucket.ISO8601Format(), start: start, end: start.addingTimeInterval(8 * 3600), asleepMinutes: offset < -6 ? 400 : 420)
        }
        var archive = history(nights, now: now)
        archive.sources.append(.init(id: "other", name: "Other source", nights: nights.map { var result = $0; result.asleepMinutes = 10; return result }))
        let comparison = try #require(ReportSleepComparison.capture(source: archive.sources.first, history: archive, now: now))
        #expect(comparison.medianChange == 20); #expect(comparison.sourceID == "watch")
        var sparse = comparison
        for index in 0..<4 { sparse.days[index].minutes = nil }
        #expect(sparse.medianChange == nil)
    }
    @Test func legacyReportsDecodeWithoutFabricatingAChartAndKeepTheirOriginalText() throws {
        let report = PersonalSleepReport(id: UUID(), createdAt: .now, provider: .apple, model: "Example", source: "Watch",
            facts: [.init(id: "health.recent", text: "One observed day")], text: "Original text")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        object.removeValue(forKey: "comparison"); object.removeValue(forKey: "followUps")
        let reopened = try JSONDecoder().decode(PersonalSleepReport.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(reopened.text == report.text); #expect(reopened.comparison == nil); #expect(reopened.followUps == nil)
        #expect(MorningBrief(report: reopened).comparison == nil)
        #expect(MorningBrief(report: reopened).takeaways.first?.text == "One observed day")
    }
}

@MainActor struct MorningBriefFollowUpTests {
    @Test func externalAnswersNeedFreshConsentAndDemoCannotSend() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let store = PersonalIntelligenceStore(directory: directory,
            snapshots: .init(directory: directory, namespace: "brief-consent", encryptionKey: { key }))
        let report = PersonalSleepReport(id: UUID(), createdAt: .now, provider: .apple, model: "Example", source: "Watch",
            facts: [.init(id: "health.sleep", text: "Frozen facts")], text: "Original")
        try store.write(.init(reports: [report]))
        let defaults = UserDefaults(suiteName: "brief-consent-\(UUID().uuidString)")!
        defaults.set("ollama", forKey: "intelligence.provider")
        let workspace = IntelligenceWorkspace(defaults: defaults, store: store, generateModel: { _ in
            .init(text: "Synthetic answer", model: "Example")
        }, protectedDataAvailable: { true })
        await PersonalWorkspaceBoundary.$suppliedActive.withValue(false) {
            AppMode.$suppliedBackend.withValue("demo") {
                workspace.followUp(report: report, question: "What changed?", consent: true)
                #expect(!workspace.reportInProgress)
            }
            await AppMode.$suppliedBackend.withValue("sleepypod-core") {
                workspace.followUp(report: report, question: "What changed?", consent: false)
                #expect(!workspace.reportInProgress)
                workspace.followUp(report: report, question: "What changed?", consent: true, valid: { false })
                #expect(!workspace.reportInProgress)
                workspace.followUp(report: report, question: "What changed?", consent: true)
                while workspace.reportInProgress { await Task.yield() }
            }
        }
        #expect(try store.read().reports.first?.followUps?.count == 1)
        PersonalWorkspaceBoundary.$suppliedActive.withValue(true) {
            workspace.followUp(report: report, question: "What changed?", consent: true)
            #expect(!workspace.reportInProgress)
        }
    }
    @Test func questionsUseFrozenFactsAndPreserveOriginalReportAcrossReplyAndScopeChanges() async throws {
        for change in ["none", "identity", "cancel", "deleted", "locked", "provider"] {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let key = SymmetricKey(size: .bits256)
            let store = PersonalIntelligenceStore(directory: directory,
                snapshots: .init(directory: directory, namespace: "brief-tests", encryptionKey: { key }))
            let report = PersonalSleepReport(id: UUID(), createdAt: .now, provider: .apple, model: "Example", source: "Watch",
                facts: [.init(id: "health.sleep", text: "Original calculated evidence")], text: "Original interpretation")
            try store.write(.init(reports: [report]))
            let state = BriefTestState(), gate = BriefReplyGate()
            let defaults = UserDefaults(suiteName: "brief-\(UUID().uuidString)")!
            let workspace = IntelligenceWorkspace(defaults: defaults, store: store, generateModel: { request in
                #expect(request.prompt.contains("Original calculated evidence"))
                #expect(!request.prompt.contains("Original interpretation"))
                await gate.wait()
                return .init(text: "Synthetic answer [health.sleep]", model: "Example answer")
            }, protectedDataAvailable: { state.unlocked }, historyScope: { state.identity })
            await AppMode.$suppliedBackend.withValue("sleepypod-core") {
                await PersonalWorkspaceBoundary.$suppliedActive.withValue(false) {
                    workspace.followUp(report: report, question: "What does this mean?", consent: false)
                    #expect(workspace.reportInProgress)
                    await gate.waitHeld()
                    switch change {
                    case "identity": state.identity = "another owner"
                    case "cancel": workspace.cancel()
                    case "deleted": try? store.write(.init())
                    case "locked": state.unlocked = false
                    case "provider": workspace.provider = .ollama
                    default: break
                    }
                    await gate.release()
                    while workspace.reportInProgress { await Task.yield() }
                }
            }
            let saved = try store.read().reports.first
            if change == "deleted" { #expect(saved == nil) }
            else {
                #expect(saved?.text == report.text); #expect(saved?.facts == report.facts); #expect(saved?.createdAt == report.createdAt)
                #expect(saved?.followUps?.count ?? 0 == (change == "none" ? 1 : 0))
            }
        }
    }
}
@MainActor private final class BriefTestState { var identity = "owner"; var unlocked = true }
private actor BriefReplyGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func waitHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
