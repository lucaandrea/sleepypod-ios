import Foundation

struct MorningJournalContext: Codable, Equatable, Sendable {
    struct Observation: Codable, Equatable, Sendable {
        var status: String
        var lastAt: Double?
        var amount: Double?
        let unit: String
        func validate(unit expectedUnit: String, maximum: Double) throws {
            guard ["not_logged", "none", "yes"].contains(status), unit == expectedUnit,
                  amount.map({ $0.isFinite && (0...maximum).contains($0) }) ?? true,
                  lastAt.map(MorningJournalContext.validInstant) ?? true,
                  status == "yes" || (lastAt == nil && amount == nil) else { throw MorningJournalFailure.invalid }
        }
    }
    var version = 1
    var bedtimeAt: Double?
    var caffeine = Observation(status: "not_logged", unit: "milligrams")
    var alcohol = Observation(status: "not_logged", unit: "usStandardDrinks")
    var exercise = Observation(status: "not_logged", unit: "minutes")
    var lastMealAt: Double?
    var stress = "not_logged"

    func validate() throws {
        guard version == 1, ["not_logged", "lower", "usual", "higher"].contains(stress),
              [bedtimeAt, lastMealAt].compactMap({ $0 }).allSatisfy(Self.validInstant) else { throw MorningJournalFailure.invalid }
        try caffeine.validate(unit: "milligrams", maximum: 10_000)
        try alcohol.validate(unit: "usStandardDrinks", maximum: 100)
        try exercise.validate(unit: "minutes", maximum: 1440)
    }
    /// The window follows local calendar days, so DST days need not be 24 hours.
    func validate(date: String, timeZone: String, now: Date) throws {
        try validate()
        guard now.timeIntervalSince1970.isFinite, TimeZone(identifier: timeZone) != nil,
              date <= MorningJournalDates.key(now, timeZone: timeZone),
              let prior = MorningJournalDates.shift(date, days: -1), let next = MorningJournalDates.shift(date, days: 1),
              let start = MorningJournalDates.localDate(prior, timeZone: timeZone),
              let end = MorningJournalDates.localDate(next, timeZone: timeZone) else { throw MorningJournalFailure.invalid }
        for instant in [bedtimeAt, lastMealAt, caffeine.lastAt, alcohol.lastAt, exercise.lastAt].compactMap({ $0 }) {
            let value = Date(timeIntervalSince1970: instant / 1000)
            guard value >= start, value < end, value <= now else {
                throw MorningJournalFailure.unavailable("Use times in the day before the wake date or the wake date itself. Future times cannot be saved.")
            }
        }
    }
    static func validInstant(_ value: Double) -> Bool {
        value.isFinite && value.rounded() == value && (0...253_402_300_799_000).contains(value)
    }
}
