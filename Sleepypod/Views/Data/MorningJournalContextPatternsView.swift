import SwiftUI

struct MorningJournalContextPatternsView: View {
    let patterns: MorningJournalContextPatterns
    var body: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Habits and feeling too warm").font(.headline).accessibilityIdentifier("journal.context.patterns")
                Text("Compare your own comfort check-ins. A result appears after five usable dates in each group.").font(.footnote).foregroundStyle(Theme.text2)
                if patterns.cohorts.isEmpty { Text("Log a little context with your morning check-in to begin.").font(.footnote) }
                ForEach(patterns.cohorts) { cohort in
                    Text("\(cohort.dates) distinct dates · \(cohort.origin == "sleepypod" ? "Core journal" : "Imported journal") · \(cohort.side.displayName) · \(cohort.timeZone)")
                        .font(.caption).foregroundStyle(Theme.text2)
                    ForEach(cohort.comparisons.filter { $0.warmRateDifferencePoints != nil }) { comparison in
                        VStack(alignment: .leading, spacing: 8) {
                            Divider()
                            Text(comparison.label).font(.subheadline.bold()).accessibilityIdentifier("journal.context.comparison.\(comparison.id)")
                            Text("\(comparison.withLabel): too warm on \(comparison.withWarmCount) of \(comparison.withCount) dates.").font(.footnote)
                            Text("\(comparison.withoutLabel): too warm on \(comparison.withoutWarmCount) of \(comparison.withoutCount) dates.").font(.footnote)
                            Text("\(comparison.differenceText ?? "") · \(comparison.excludedCount) entries excluded. Association only.")
                                .font(.footnote).foregroundStyle(Theme.text2)
                        }
                    }
                    if !cohort.comparisons.contains(where: { $0.warmRateDifferencePoints != nil }) {
                        Text("No comparison has enough usable dates yet.").font(.footnote)
                    }
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(cohort.comparisons) { comparison in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(comparison.label).font(.subheadline)
                                    Text("\(comparison.withLabel): \(comparison.withCount) · \(comparison.withoutLabel): \(comparison.withoutCount) · Excluded: \(comparison.excludedCount)")
                                        .font(.caption).foregroundStyle(Theme.text2).accessibilityIdentifier("journal.context.definition.\(comparison.id)")
                                }
                            }
                        }.padding(.top, 12).frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Comparison definitions and counts").multilineTextAlignment(.leading)
                            .accessibilityIdentifier("journal.context.definitions")
                    }
                }
                Text(patterns.note).font(.caption).foregroundStyle(Theme.text2)
            }.padding(16)
        }
    }
}
