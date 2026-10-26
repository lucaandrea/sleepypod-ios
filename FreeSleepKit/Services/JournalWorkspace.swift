import Foundation
import Observation

@MainActor @Observable
final class JournalWorkspace {
    private(set) var drafts: [String: JournalEntry] = [:]
    private(set) var demoEntries: [String: JournalEntry] = [:]
    private(set) var saving: Set<String> = []
    private(set) var revision = 0
    func beginSave(_ key: String) -> Bool { saving.insert(key).inserted }
    func finishSave(_ key: String) { saving.remove(key) }
    func saved() { revision += 1 }
    func put(_ key: String, value: JournalEntry) { drafts[key] = value }
    func clear(_ key: String, expected: JournalEntry? = nil) {
        if let expected, drafts[key] != expected { return }
        drafts[key] = nil
    }
    func saveDemo(_ key: String, value: JournalEntry) -> JournalEntry {
        var saved = value; saved.notes = saved.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        demoEntries[key] = saved; return saved
    }
    func demoJournal(key: String, date: String, side: String, days: Int, nights: [SleepAnalytics.Night]? = nil) -> Journal {
        let entries = demoEntries.values.filter { $0.side == side }
        let nights = nights ?? SleepDemo.shared?.ranges[String(days)]?.nights ?? []
        let matches = entries.compactMap { entry -> (JournalEntry, Double)? in
            guard let presence = nights.first(where: { $0.date == entry.date })?.occupiedMinutes else { return nil }
            return (entry, presence)
        }
        let habits: [(String, KeyPath<JournalEntry, Bool>)] = [("caffeine", \.caffeine), ("alcohol", \.alcohol), ("exercise", \.exercise)]
        let associations = habits.compactMap { habit in Self.association(name: habit.0, property: habit.1, matches: matches) }
        return Journal(entries: Array(entries), selectedDate: date, selected: demoEntries[key], timeZone: "America/Los_Angeles",
                       patterns: .init(associations: associations, note: Journal.patternNote))
    }
    /// Keep the two sample means explicit for older Swift type-checkers; retain the five-per-group threshold.
    private static func association(name: String, property: KeyPath<JournalEntry, Bool>,
                                    matches: [(JournalEntry, Double)]) -> Journal.Patterns.Association? {
        let withHabit = matches.filter { $0.0[keyPath: property] }
        let withoutHabit = matches.filter { !$0.0[keyPath: property] }
        guard withHabit.count >= 5, withoutHabit.count >= 5 else { return nil }
        let withTotal: Double = withHabit.reduce(0.0) { total, match in total + match.1 }
        let withoutTotal: Double = withoutHabit.reduce(0.0) { total, match in total + match.1 }
        let withMean = withTotal / Double(withHabit.count)
        let withoutMean = withoutTotal / Double(withoutHabit.count)
        return .init(habit: name, withCount: withHabit.count, withoutCount: withoutHabit.count,
                     presenceDifferenceMinutes: Int(floor(withMean - withoutMean + 0.5)))
    }
}

enum JournalDate {
    static func key(_ date: Date, timeZone: String) -> String { formatter(timeZone).string(from: date) }
    static func date(_ key: String, timeZone: String) -> Date? {
        let clock = formatter(timeZone)
        guard let date = clock.date(from: key), clock.string(from: date) == key else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = clock.timeZone
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date)
    }
    private static func formatter(_ timeZone: String) -> DateFormatter {
        let result = DateFormatter(); result.calendar = Calendar(identifier: .gregorian)
        result.locale = Locale(identifier: "en_US_POSIX"); result.timeZone = TimeZone(identifier: timeZone) ?? .gmt
        result.dateFormat = "yyyy-MM-dd"; result.isLenient = false; return result
    }
}
