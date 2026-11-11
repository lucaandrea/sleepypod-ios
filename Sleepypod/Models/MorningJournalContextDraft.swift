import Foundation

struct MorningJournalContextDraft: Equatable, Sendable {
    struct Time: Equatable, Sendable {
        var wall = ""
        var occurrence: Double?
        init(_ instant: Double? = nil, timeZone: String) {
            if let instant { wall = MorningJournalContextClock.wallTime(instant, timeZone: timeZone); occurrence = floor(instant / 60_000) * 60_000 }
        }
        func resolved(timeZone: String) throws -> Double? {
            if wall.isEmpty { return nil }
            let candidates = MorningJournalContextClock.candidates(wall, timeZone: timeZone)
            guard !candidates.isEmpty else {
                throw MorningJournalFailure.unavailable("This clock time does not exist in the entry’s time zone. Check the date and time.")
            }
            if candidates.count == 1 { return candidates[0] }
            guard let occurrence, candidates.contains(occurrence) else {
                throw MorningJournalFailure.unavailable("This clock time occurs twice when daylight saving ends. Choose the earlier or later occurrence.")
            }
            return occurrence
        }
    }
    struct Habit: Equatable, Sendable {
        var status: String
        var amount: String
        var time: Time
        let unit: String
        init(_ observation: MorningJournalContext.Observation?, legacy: Bool, unit: String, timeZone: String) {
            status = observation?.status ?? (legacy ? "yes" : "not_logged")
            amount = observation?.amount.map(String.init(describing:)) ?? ""
            time = Time(observation?.lastAt, timeZone: timeZone); self.unit = unit
        }
        func resolved(timeZone: String, locale: Locale) throws -> MorningJournalContext.Observation {
            guard status == "yes" else { return .init(status: status, unit: unit) }
            let trimmed = amount.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed.replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")
            let quantity: Double?
            if normalized.isEmpty { quantity = nil }
            else {
                guard normalized.range(of: #"^\d+(?:\.\d*)?$"#, options: .regularExpression) != nil,
                      let parsed = Double(normalized), parsed.isFinite else {
                    throw MorningJournalFailure.unavailable("Enter a nonnegative amount, or leave it blank when unknown.")
                }
                quantity = parsed
            }
            return try .init(status: status, lastAt: time.resolved(timeZone: timeZone), amount: quantity, unit: unit)
        }
    }
    var caffeine: Habit
    var alcohol: Habit
    var exercise: Habit
    var bedtime: Time
    var meal: Time
    var stress: String

    init(fields: MorningJournalFields, timeZone: String) {
        let context = fields.context
        caffeine = Habit(context?.caffeine, legacy: fields.caffeine, unit: "milligrams", timeZone: timeZone)
        alcohol = Habit(context?.alcohol, legacy: fields.alcohol, unit: "usStandardDrinks", timeZone: timeZone)
        exercise = Habit(context?.exercise, legacy: fields.exercise, unit: "minutes", timeZone: timeZone)
        bedtime = Time(context?.bedtimeAt, timeZone: timeZone); meal = Time(context?.lastMealAt, timeZone: timeZone)
        stress = context?.stress ?? "not_logged"
    }
    func fields(from original: MorningJournalFields, date: String, timeZone: String, now: Date = .now, locale: Locale = .current) throws -> MorningJournalFields {
        var result = original
        let context = try MorningJournalContext(bedtimeAt: bedtime.resolved(timeZone: timeZone),
            caffeine: caffeine.resolved(timeZone: timeZone, locale: locale), alcohol: alcohol.resolved(timeZone: timeZone, locale: locale),
            exercise: exercise.resolved(timeZone: timeZone, locale: locale), lastMealAt: meal.resolved(timeZone: timeZone), stress: stress)
        do { try context.validate() }
        catch { throw MorningJournalFailure.unavailable("Check the optional quantities. Maximums are 10,000 mg, 100 US standard drinks and 1,440 minutes; leave unknown amounts blank.") }
        try context.validate(date: date, timeZone: timeZone, now: now)
        result.context = context; result.caffeine = context.caffeine.status == "yes"
        result.alcohol = context.alcohol.status == "yes"; result.exercise = context.exercise.status == "yes"
        return result
    }
}
