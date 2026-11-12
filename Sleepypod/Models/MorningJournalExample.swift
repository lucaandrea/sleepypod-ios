import Foundation

struct MorningJournalExample: Decodable, Sendable {
    let synthetic: Bool
    let sourceCommit: String
    let page: MorningJournalPage
    static func load(context: Bool = false) throws -> Self {
        guard let url = Bundle.main.url(forResource: context ? "morning-journal-context-example" : "morning-journal-example", withExtension: "json") else { throw MorningJournalFailure.invalid }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

actor DemoMorningJournalClient: MorningJournalClient {
    private let scenario: String
    private var selections: [String: MorningJournalSelection] = [:]
    private var initialized = false
    private var injectedFailure = false
    private var changedTimeZone: String?
    init(scenario: String = "empty") { self.scenario = scenario }
    func available() throws {
        if scenario == "offline" { throw URLError(.notConnectedToInternet) }
    }
    func read(side: Side, date: String?, days: Int) throws -> MorningJournalPage {
        try available()
        let example = try MorningJournalExample.load(context: scenario.hasPrefix("context")).page
        if !initialized {
            if scenario != "empty" && scenario != "context-zone" { for entry in example.entries { selections[key(entry.side, entry.date)] = entry } }
            if scenario == "context-fold", let record = example.selected.record,
               let earlier = ISO8601DateFormatter().date(from: "2026-11-01T08:30:00Z") {
                var fields = record.fields
                fields.context?.caffeine.lastAt = earlier.timeIntervalSince1970 * 1000
                let input = MorningJournalWrite(side: record.side, date: record.date, expectedRevision: example.selected.revision, fields: fields)
                selections[key(record.side, record.date)] = saved(input, fields: fields, original: record)
            }
            initialized = true
        }
        let today = scenario == "empty" ? MorningJournalDates.key(.now, timeZone: example.timeZone) : example.deviceDate
        let through = date ?? today, from = max("1970-01-01", MorningJournalDates.shift(through, days: 1 - days) ?? through)
        let selected = selections[key(side, through)] ?? .init(side: side, date: through, revision: nil, record: nil)
        let entries = selections.values.filter { $0.side == side && $0.date >= from && $0.date <= through && $0.record != nil }.sorted { $0.date > $1.date }
        let recent = entries.prefix(7).compactMap(\.record)
        let average: Double? = recent.isEmpty ? nil : (Double(recent.reduce(0) { $0 + $1.fields.restfulness }) / Double(recent.count) * 10).rounded() / 10
        // Source-generated cohorts are shown only with their exact synthetic evidence set.
        let cohorts = entries == example.entries ? example.patterns.cohorts : []
        return .init(apiVersion: 1, side: side, timeZone: changedTimeZone ?? example.timeZone, deviceDate: today, from: from, through: through, selected: selected, entries: entries,
                     patterns: .init(recentEntries: recent.count, averageRestfulness: average, warmCount: recent.filter { $0.fields.comfort == "warm" }.count,
                                     coldCount: recent.filter { $0.fields.comfort == "cold" }.count, cohorts: cohorts, note: example.patterns.note),
                     contextVersion: example.contextVersion,
                     contextPatterns: entries == example.entries ? example.contextPatterns : (example.contextVersion == 1 ? .init(cohorts: [], note: "Synthetic preview. Recomputed comparisons are unavailable after editing this fixture.") : nil))
    }
    func write(_ input: MorningJournalWrite) throws -> MorningJournalSelection {
        try available(); try input.fields?.validate()
        let entryKey = key(input.side, input.date), current = selections[entryKey]
        guard current?.revision == input.expectedRevision else { throw MorningJournalFailure.conflict }
        if scenario == "context-zone", !injectedFailure {
            injectedFailure = true; changedTimeZone = "America/New_York"; throw MorningJournalFailure.conflict
        }
        let zone = current?.record?.timeZone ?? changedTimeZone ?? "America/Los_Angeles"
        guard input.expectedTimeZone == nil || input.expectedTimeZone == zone else { throw MorningJournalFailure.conflict }
        try input.fields?.context?.validate(date: input.date, timeZone: zone, now: .now)
        if ["conflict", "context-conflict"].contains(scenario), !injectedFailure {
            injectedFailure = true
            var fields = current?.record?.fields ?? .init(); fields.comfort = "cold"; fields.notes = "Synthetic edit from another device."
            if scenario == "context-conflict" {
                fields.context?.caffeine = .init(status: "not_logged", unit: "milligrams")
                fields.context?.alcohol = .init(status: "yes", amount: 0, unit: "usStandardDrinks")
                fields.context?.exercise.amount = 42
                let lastMeal = fields.context?.bedtimeAt.map { $0 - 7_200_000 }
                fields.context?.lastMealAt = lastMeal
                fields.context?.stress = "higher"
                fields.caffeine = false; fields.alcohol = true
            }
            selections[entryKey] = saved(input, fields: fields, original: current?.record)
            throw MorningJournalFailure.conflict
        }
        let result = saved(input, fields: input.fields?.normalized, original: current?.record)
        selections[entryKey] = result
        if ["lost-save", "context-lost-save"].contains(scenario), !injectedFailure { injectedFailure = true; throw URLError(.networkConnectionLost) }
        return result
    }
    private func saved(_ input: MorningJournalWrite, fields: MorningJournalFields?, original: MorningJournalRecord?) -> MorningJournalSelection {
        let now = (Date.now.timeIntervalSince1970 * 1000).rounded()
        let record = fields.map { MorningJournalRecord(side: input.side, date: input.date, fields: $0,
            timeZone: original?.timeZone ?? changedTimeZone ?? "America/Los_Angeles", origin: original?.origin ?? "sleepypod",
            createdAt: original == nil ? now : original?.createdAt, updatedAt: now, importedAt: original?.importedAt) }
        return .init(side: input.side, date: input.date, revision: UUID().uuidString.lowercased(), record: record)
    }
    private func key(_ side: Side, _ date: String) -> String { "\(side.rawValue)|\(date)" }
}
