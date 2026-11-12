import Foundation

/// Highlights come from calculated evidence, never from guessing numbers in model prose.
struct MorningBrief: Sendable {
    struct Takeaway: Identifiable, Sendable {
        var id: String
        var title: String
        var text: String
        var badge: String
    }
    let report: PersonalSleepReport
    var comparison: ReportSleepComparison? { report.comparison.flatMap { $0.isValid && $0.asOf <= report.createdAt ? $0 : nil } }
    var takeaways: [Takeaway] {
        if let comparison {
            let latest = comparison.latest
            let latestText = latest.flatMap { day in day.minutes.map {
                "\(ReportSleepComparison.duration($0)) recorded for the sleep day ending \(comparison.dateLabel(day.end)). This may include naps or a partial recording."
            } } ?? "No recorded sleep in this 14-day view. Missing data does not establish no sleep."
            let change = comparison.medianChange
            let changeText = change.map {
                "\(Int(abs($0).rounded())) minutes \($0 >= 0 ? "more" : "less") in the recent seven-day median than the prior seven, using \(comparison.recentValues.count) and \(comparison.priorValues.count) recorded days. This is a descriptive difference."
            } ?? "\(comparison.recentValues.count) recorded days in the recent seven and \(comparison.priorValues.count) in the prior seven. At least four in each period are needed for this comparison."
            return [
                .init(id: "latest", title: "Latest recorded sleep", text: latestText, badge: latest == nil ? "Missing data" : "Source estimate"),
                .init(id: "comparison", title: "Compared with the week before", text: changeText, badge: change == nil ? "Limited coverage" : "Same source"),
                .init(id: "coverage", title: "How much is recorded", text: "\(comparison.observedCount) of 14 noon-to-noon days have observations. Unknown days remain gaps; recorded days are not automatically complete nights.", badge: "\(comparison.observedCount)/14 days")
            ]
        }
        let priority = ["health.sleep", "health.change", "health.recent", "health.coverage", "pod.coverage", "pod.occupancy", "health.timing"]
        let selected = priority.compactMap { identifier in report.facts.first { $0.id == identifier } }.prefix(3)
        return selected.map { .init(id: $0.id, title: ReportEvidenceLabel.title($0.id), text: $0.text, badge: "Saved evidence") }
    }
}
