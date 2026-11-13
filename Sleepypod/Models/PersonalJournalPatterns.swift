import Foundation

struct PersonalJournalRange: Codable, Equatable, Sendable {
    let from: String
    let through: String
    func validate() throws {
        guard MorningJournalDates.valid(from), MorningJournalDates.valid(through), from <= through,
              let start = MorningJournalDates.localDate(from, timeZone: "GMT"),
              let end = MorningJournalDates.localDate(through, timeZone: "GMT"),
              end.timeIntervalSince(start) < 90 * 86_400 else { throw HouseholdFailure.invalid }
    }
}

/// Aggregated personal self-reports retain time zones but contain no notes, raw entries or mattress-side identity.
struct PersonalJournalPatterns: Codable, Equatable, Sendable {
    struct Cohort: Codable, Equatable, Sendable, Identifiable {
        let timeZone: String
        let dates: Int
        let comparisons: [MorningJournalContextPatterns.Comparison]
        var id: String { timeZone }
    }
    let version: Int
    let generatedAt: Int64
    let scope: PersonalHistoryScope
    let interpretation: String
    let query: PersonalJournalRange
    let source: String
    let minimumDatesPerGroup: Int
    let cohorts: [Cohort]
    let note: String

    static func decodeExact(_ data: Data) throws -> Self {
        try PersonalJournalDecoding.patterns(data)
        return try JSONDecoder().decode(Self.self, from: data)
    }
    func validate(for session: HouseholdSession, range: PersonalJournalRange) throws {
        try PersonalJournalContract.envelope(version: version, generatedAt: generatedAt, interpretation: interpretation, scope: scope, session: session)
        try query.validate()
        guard query == range, source == "personal_journal", minimumDatesPerGroup == 5, note.utf16.count <= 1_200,
              cohorts.count <= 90, Set(cohorts.map(\.timeZone)).count == cohorts.count else { throw HouseholdFailure.invalid }
        var total = 0
        for cohort in cohorts {
            guard PersonalJournalContract.zone(cohort.timeZone), (0...90).contains(cohort.dates),
                  (5...8).contains(cohort.comparisons.count),
                  Set(cohort.comparisons.map(\.id)).count == cohort.comparisons.count else { throw HouseholdFailure.invalid }
            total += cohort.dates
            for comparison in cohort.comparisons {
                do { try comparison.validate(entryCount: cohort.dates) } catch { throw HouseholdFailure.invalid }
                guard [comparison.label, comparison.withLabel, comparison.withoutLabel].allSatisfy({ $0.utf16.count <= 120 }),
                      comparison.withCount + comparison.withoutCount + comparison.excludedCount == cohort.dates,
                      comparison.quantityThreshold.map({ $0 <= 10_000 }) ?? true else { throw HouseholdFailure.invalid }
            }
        }
        guard total <= 90 else { throw HouseholdFailure.invalid }
    }
}
