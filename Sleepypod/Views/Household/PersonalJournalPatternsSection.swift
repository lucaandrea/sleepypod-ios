import SwiftUI

struct PersonalJournalPatternsSection: View {
    let model: PersonalJournalPatternsWorkspace
    let today: String
    @State private var expanded = false
    @State private var from: Date
    @State private var through: Date
    init(model: PersonalJournalPatternsWorkspace, wakeDate: String, today: String) {
        self.model = model; self.today = today
        let end = min(wakeDate, today)
        let start = max("1970-01-01", MorningJournalDates.shift(end, days: -29) ?? end)
        _from = State(initialValue: MorningJournalDates.localDate(start, timeZone: "GMT") ?? .now)
        _through = State(initialValue: MorningJournalDates.localDate(end, timeZone: "GMT") ?? .now)
    }
    var body: some View {
        if model.available {
            Section {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Compare your saved check-ins. Each difference needs five usable dates in both groups. Unsaved changes and preserved legacy records are not included.")
                            .font(.footnote).foregroundStyle(Theme.text2)
                        let earliest = Date(timeIntervalSince1970: 0)
                        let latest = MorningJournalDates.localDate(today, timeZone: "GMT") ?? .now
                        DatePicker("Compare from", selection: $from, in: earliest...latest, displayedComponents: .date)
                            .accessibilityIdentifier("personalPatterns.from")
                        DatePicker("Compare through", selection: $through, in: earliest...latest, displayedComponents: .date)
                            .accessibilityIdentifier("personalPatterns.through")
                        Button("Compare saved check-ins") {
                            let range = PersonalJournalRange(from: MorningJournalDates.key(from, timeZone: "GMT"),
                                through: MorningJournalDates.key(through, timeZone: "GMT"))
                            Task { await model.load(range) }
                        }.buttonStyle(.borderless).disabled(!model.enabled || model.busy).accessibilityIdentifier("personalPatterns.compare")
                        if model.busy { ProgressView("Comparing saved check-ins…").accessibilityIdentifier("personalPatterns.loading") }
                        if let error = model.error { Text(error).font(.footnote).accessibilityIdentifier("personalPatterns.error") }
                        if let result = model.result { PersonalJournalPatternResults(result: result) }
                    }.padding(.vertical, 8).environment(\.timeZone, .gmt)
                } label: {
                    Text("Habits and feeling too warm").accessibilityIdentifier("personalPatterns.open")
                }
            }
            .onChange(of: expanded) { if !expanded { model.clear() } }
            .onChange(of: from) { model.clear() }
            .onChange(of: through) { model.clear() }
            .onDisappear { model.clear() }
        }
    }
}

private struct PersonalJournalPatternResults: View {
    let result: PersonalJournalPatterns
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Saved check-ins from \(result.query.from) through \(result.query.through). Read \(Date(timeIntervalSince1970: Double(result.generatedAt) / 1000).formatted(date: .abbreviated, time: .shortened)).")
                .font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("personalPatterns.source")
            if result.cohorts.isEmpty {
                Text("No saved check-ins in this range. Add a little optional context to a morning check-in to begin.")
                    .font(.footnote).accessibilityIdentifier("personalPatterns.empty")
            }
            ForEach(result.cohorts) { cohort in
                Divider()
                Text("\(cohort.dates) saved dates · \(cohort.timeZone)").font(.subheadline.weight(.semibold))
                ForEach(cohort.comparisons.filter { $0.warmRateDifferencePoints != nil }) { comparison in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(comparison.label).font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("personalPatterns.finding.\(comparison.id)")
                        Text("\(comparison.withLabel): too warm on \(comparison.withWarmCount) of \(comparison.withCount) dates.").font(.footnote)
                            .accessibilityIdentifier("personalPatterns.withCount.\(comparison.id)")
                        Text("\(comparison.withoutLabel): too warm on \(comparison.withoutWarmCount) of \(comparison.withoutCount) dates.").font(.footnote)
                            .accessibilityIdentifier("personalPatterns.withoutCount.\(comparison.id)")
                        Text("\(comparison.excludedCount) entries excluded · \(comparison.differenceText ?? ""). Association only.")
                            .font(.footnote).foregroundStyle(Theme.text2)
                            .accessibilityIdentifier("personalPatterns.caveat.\(comparison.id)")
                    }.padding(.vertical, 4)
                }
                if !cohort.comparisons.contains(where: { $0.warmRateDifferencePoints != nil }) {
                    Text("No comparison has enough usable dates yet.").font(.footnote).accessibilityIdentifier("personalPatterns.insufficient")
                }
                DisclosureGroup {
                    ForEach(cohort.comparisons) { comparison in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(comparison.label).font(.subheadline)
                            Text("\(comparison.withLabel): \(comparison.withCount) · \(comparison.withoutLabel): \(comparison.withoutCount) · Excluded: \(comparison.excludedCount)")
                                .font(.footnote).foregroundStyle(Theme.text2)
                                .accessibilityIdentifier("personalPatterns.definition.\(comparison.id)")
                        }.padding(.vertical, 6)
                    }
                } label: {
                    Text("Comparison definitions and counts").accessibilityIdentifier("personalPatterns.definitions")
                }
            }
            Text(result.note).font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("personalPatterns.note")
        }
        // Expanded definitions must not compress sibling counts or caveats in the Form row.
        .fixedSize(horizontal: false, vertical: true)
    }
}
