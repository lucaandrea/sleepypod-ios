import Foundation

// Live receipts come from the server. The editable demo is checked against the shared server-generated fixture.
enum DemoCoachFacts {
    static func grounding(_ analytics: SleepAnalytics, observations: [String]) -> CoachGrounding? {
        guard let coverage = analytics.quality?.coverage else { return nil }
        let recent = coverage.recent; let previous = coverage.previous
        let context = recent.map { "\($0.from) → \($0.through) · \(analytics.timeZone)" } ?? "Selected history · \(analytics.timeZone)"
        var facts: [CoachGrounding.Fact] = []
        func add(_ identifier: String, _ title: String, _ sample: String, _ calculation: String, scope: String? = nil) {
            guard facts.count < observations.count else { return }
            facts.append(.init(id: identifier, title: title, observation: observations[facts.count], context: scope ?? context,
                               sample: sample, calculation: calculation))
        }
        if analytics.summary.averageOccupiedMinutes != nil {
            add("bed-presence", "Bed presence", "\(recent?.presenceNights ?? 0) nights with known presence",
                "Mean of known bed-presence durations from the longest episode per wake date, rounded to the nearest minute. "
                + "Missing or unknown presence is excluded. Presence is not measured sleep.")
        }
        if analytics.summary.bedtimeVariationMinutes != nil {
            add("bedtime-variation", "Bed-entry consistency", "\(recent?.recordedNights ?? 0) recorded nights",
                "Population standard deviation of bed-entry clock times across recorded main episodes, "
                + "rounded to the nearest minute. Lower values mean more consistent timing; they do not measure sleep quality.")
        }
        if analytics.summary.weeklyChangeMinutes != nil, coverage.comparisonAvailable, let recent, let previous {
            add("weekly-presence-change", "Weekly presence change",
                "\(recent.presenceNights) recent and \(previous.presenceNights) previous nights with known presence",
                "Recent mean bed presence minus the previous mean, using only known-presence nights. "
                + "Each period needs at least three. This describes the available records and does not establish a cause.",
                scope: "\(context) · Previous: \(previous.from) → \(previous.through)")
        }
        if facts.isEmpty {
            add("no-presence-summary", "Limited observations", "\(recent?.presenceNights ?? 0) nights with known presence",
                "No presence-duration or timing observation can be produced from the returned records. No missing value is filled with zero.")
        }
        return .init(version: 1, facts: facts, suggestions: "rules")
    }
}
