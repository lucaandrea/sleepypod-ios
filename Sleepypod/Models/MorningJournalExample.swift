import Foundation

struct MorningJournalExample: Decodable, Sendable {
    let synthetic: Bool
    let sourceCommit: String
    let page: MorningJournalPage
    static func load() throws -> Self {
        guard let url = Bundle.main.url(forResource: "morning-journal-example", withExtension: "json") else { throw MorningJournalFailure.invalid }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

actor DemoMorningJournalClient: MorningJournalClient {
    private let scenario: String
    private var selections: [String: MorningJournalSelection] = [:]
    private var initialized = false
    private var injectedFailure = false
    init(scenario: String = "empty") { self.scenario = scenario }
    func available() throws {
        if scenario == "offline" { throw URLError(.notConnectedToInternet) }
    }
    func read(side: Side, date: String?, days: Int) throws -> MorningJournalPage {
        try available()
        let example = try MorningJournalExample.load().page
        if !initialized {
            if scenario != "empty" { for entry in example.entries { selections[key(entry.side, entry.date)] = entry } }
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
        return .init(apiVersion: 1, side: side, timeZone: example.timeZone, deviceDate: today, from: from, through: through, selected: selected, entries: entries,
                     patterns: .init(recentEntries: recent.count, averageRestfulness: average, warmCount: recent.filter { $0.fields.comfort == "warm" }.count,
                                     coldCount: recent.filter { $0.fields.comfort == "cold" }.count, cohorts: cohorts, note: example.patterns.note))
    }
    func write(_ input: MorningJournalWrite) throws -> MorningJournalSelection {
        try available(); try input.fields?.validate()
        let entryKey = key(input.side, input.date), current = selections[entryKey]
        guard current?.revision == input.expectedRevision else { throw MorningJournalFailure.conflict }
        if scenario == "conflict", !injectedFailure {
            injectedFailure = true
            var fields = current?.record?.fields ?? .init(); fields.comfort = "cold"; fields.notes = "Synthetic edit from another device."
            selections[entryKey] = saved(input, fields: fields, original: current?.record)
            throw MorningJournalFailure.conflict
        }
        let result = saved(input, fields: input.fields?.normalized, original: current?.record)
        selections[entryKey] = result
        if scenario == "lost-save", !injectedFailure { injectedFailure = true; throw URLError(.networkConnectionLost) }
        return result
    }
    private func saved(_ input: MorningJournalWrite, fields: MorningJournalFields?, original: MorningJournalRecord?) -> MorningJournalSelection {
        let now = (Date.now.timeIntervalSince1970 * 1000).rounded()
        let record = fields.map { MorningJournalRecord(side: input.side, date: input.date, fields: $0,
            timeZone: original?.timeZone ?? "America/Los_Angeles", origin: original?.origin ?? "sleepypod",
            createdAt: original == nil ? now : original?.createdAt, updatedAt: now, importedAt: original?.importedAt) }
        return .init(side: input.side, date: input.date, revision: UUID().uuidString.lowercased(), record: record)
    }
    private func key(_ side: Side, _ date: String) -> String { "\(side.rawValue)|\(date)" }
}
