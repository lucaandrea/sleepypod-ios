#if DEBUG
import SwiftUI

/// Isolated presentation practice; it cannot read private archives or dispatch a model request.
public struct MorningBriefExample: View {
    public init() {}
    public var body: some View { NavigationStack { MorningBriefScreen(report: Self.report, example: true) } }
    private static var report: PersonalSleepReport {
        let scenario = UserDefaults.standard.string(forKey: "uiBriefScenario") ?? "complete"
        var report = ReportPresentationExample.report
        report.createdAt = ISO8601DateFormatter().date(from: "2026-11-11T17:00:00Z")!
        if scenario == "legacy" { return report }
        if scenario == "empty" { report.text = "### Your recent pattern\nNo observations were supplied. No experiment is proposed." }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let current = HealthHistoryAnalyzer.bucket(for: report.createdAt, calendar: calendar)
        let nights = (-13...0).compactMap { offset -> HealthHistory.Night? in
            if scenario == "empty" || offset == -3 || (scenario == "sparse" && offset < -1) { return nil }
            let bucket = calendar.date(byAdding: .day, value: offset, to: current)!
            let start = bucket.addingTimeInterval(10 * 3600)
            return .init(id: bucket.ISO8601Format(), start: start, end: start.addingTimeInterval(8 * 3600),
                         asleepMinutes: offset < -6 ? 410 : 445)
        }
        let source = HealthHistory.Source(id: "example", name: "Example Watch · synthetic observations", nights: nights)
        let history = HealthHistory(importedAt: report.createdAt, timeZone: calendar.timeZone.identifier,
                                    sources: [source], ignoredSamples: 0)
        report.comparison = ReportSleepComparison.capture(source: source, history: history, now: report.createdAt)
        report.facts = HealthHistoryAnalyzer.facts(source: source, now: report.createdAt, timeZone: calendar.timeZone)
        report.followUps = [.init(id: UUID(uuidString: "10000000-0000-4000-8000-000000000002")!, createdAt: report.createdAt,
            question: "Does a longer recording mean I slept better?",
            text: "**Not by itself.** Recorded duration is a source estimate and can include partial nights or naps. These observations do not establish a benefit from a routine change. [health.recent]",
            provider: .apple, model: "Example local answer")]
        return report
    }
}
#endif
