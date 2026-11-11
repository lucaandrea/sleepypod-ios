import SwiftUI

/// Show the complete saved context before the user chooses which draft to keep.
struct MorningJournalSavedContext: View {
    let context: MorningJournalContext
    let timeZone: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved habit details").font(.subheadline.weight(.semibold))
            Text("Original time zone: \(timeZone)").font(.caption).foregroundStyle(Theme.text2)
                .accessibilityIdentifier("journal.saved.timeZone")
            habit("Caffeine", identifier: "caffeine", observation: context.caffeine, unit: "mg", timeLabel: "Last caffeine")
            habit("Alcohol", identifier: "alcohol", observation: context.alcohol, unit: "US standard drinks", timeLabel: "Last drink")
            habit("Exercise", identifier: "exercise", observation: context.exercise, unit: "minutes", timeLabel: "Finished")
            Text("Reported bedtime: \(clock(context.bedtimeAt))")
                .accessibilityIdentifier("journal.saved.bedtime")
            Text("Last meal: \(clock(context.lastMealAt))")
                .accessibilityIdentifier("journal.saved.meal")
            Text("Stress: \(context.stress == "not_logged" ? "Not logged" : context.stress.capitalized)")
                .accessibilityIdentifier("journal.saved.stress")
        }.font(.footnote)
    }

    private func habit(_ title: String, identifier: String, observation: MorningJournalContext.Observation, unit: String, timeLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title): \(status(observation.status))")
                .fontWeight(.medium).accessibilityIdentifier("journal.saved.\(identifier).status")
            if observation.status == "yes" {
                Text(observation.amount.map { "\($0.formatted(.number.precision(.significantDigits(1...15)))) \(unit)" } ?? "Quantity not logged")
                    .accessibilityIdentifier("journal.saved.\(identifier).amount")
                Text("\(timeLabel): \(clock(observation.lastAt))")
                    .accessibilityIdentifier("journal.saved.\(identifier).time")
            }
        }
    }

    private func status(_ value: String) -> String {
        switch value {
        case "yes": "Yes"
        case "none": "None"
        default: "Not logged"
        }
    }

    private func clock(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "Not logged" }
        guard let zone = TimeZone(identifier: timeZone) else { return "Time zone unavailable" }
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        // Include the zone abbreviation so repeated daylight-saving minutes remain distinct.
        let formatted = date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: zone))
        return "\(formatted) \(zone.abbreviation(for: date) ?? timeZone)"
    }
}
