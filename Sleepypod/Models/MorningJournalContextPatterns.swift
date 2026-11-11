import Foundation

struct MorningJournalContextPatterns: Codable, Equatable, Sendable {
    struct Comparison: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let label: String
        let withLabel: String
        let withoutLabel: String
        let withCount: Int
        let withoutCount: Int
        let excludedCount: Int
        let withWarmCount: Int
        let withoutWarmCount: Int
        let warmRateDifferencePoints: Double?
        let quantityThreshold: Double?

        var differenceText: String? {
            guard let difference = warmRateDifferencePoints else { return nil }
            if difference == 0 { return "No difference at this precision (0 percentage points)" }
            return "\(abs(difference).formatted()) percentage points \(difference < 0 ? "lower" : "higher") in the first group"
        }
        func validate(entryCount: Int) throws {
            let known = ["caffeine-time", "alcohol-time", "exercise-time", "meal-time", "stress", "caffeine-amount", "alcohol-amount", "exercise-amount"]
            guard known.contains(id), [label, withLabel, withoutLabel].allSatisfy({ !$0.isEmpty && $0.count <= 200 }),
                  [withCount, withoutCount, excludedCount].allSatisfy({ (0...entryCount).contains($0) }),
                  withCount + withoutCount + excludedCount <= entryCount,
                  (0...withCount).contains(withWarmCount), (0...withoutCount).contains(withoutWarmCount),
                  quantityThreshold.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw MorningJournalFailure.invalid }
            if withCount >= 5 && withoutCount >= 5 {
                // Match the server's Math.round, including negative half steps.
                let expected = floor((Double(withWarmCount) / Double(withCount) - Double(withoutWarmCount) / Double(withoutCount)) * 1000 + 0.5) / 10
                guard let difference = warmRateDifferencePoints, difference.isFinite, abs(difference - expected) <= 0.0001 else { throw MorningJournalFailure.invalid }
            } else if warmRateDifferencePoints != nil { throw MorningJournalFailure.invalid }
        }
    }
    struct Cohort: Codable, Equatable, Sendable, Identifiable {
        let side: Side
        let origin: String
        let timeZone: String
        let dates: Int
        let comparisons: [Comparison]
        var id: String { "\(side.rawValue)|\(origin)|\(timeZone)" }
    }
    let cohorts: [Cohort]
    let note: String
    func validate(side: Side, entries: [MorningJournalSelection]) throws {
        guard cohorts.count <= 90, Set(cohorts.map(\.id)).count == cohorts.count, note.count <= 3000 else { throw MorningJournalFailure.invalid }
        for cohort in cohorts {
            let records = entries.compactMap(\.record).filter { $0.side == side && $0.origin == cohort.origin && $0.timeZone == cohort.timeZone }
            guard cohort.side == side, ["free-sleep", "sleepypod"].contains(cohort.origin), TimeZone(identifier: cohort.timeZone) != nil,
                  cohort.dates == records.count, cohort.comparisons.count <= 8,
                  Set(cohort.comparisons.map(\.id)).count == cohort.comparisons.count else { throw MorningJournalFailure.invalid }
            for comparison in cohort.comparisons { try comparison.validate(entryCount: records.count) }
        }
    }
}
