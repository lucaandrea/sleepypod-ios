import Foundation

enum MorningJournalFailure: LocalizedError, Equatable {
    case conflict, invalid, unavailable(String)
    var errorDescription: String? {
        switch self {
        case .conflict: "This check-in changed on another device. Your draft is kept. Read the saved entry before choosing what to keep."
        case .invalid: "The controller returned an inconsistent journal entry. Reload before editing."
        case .unavailable(let message): message
        }
    }
}

struct MorningJournalFields: Codable, Equatable, Sendable {
    var restfulness = 3
    var comfort = "comfortable"
    var caffeine = false
    var alcohol = false
    var exercise = false
    var notes = ""
    var normalized: Self {
        var result = self; result.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines); return result
    }
    func validate() throws {
        guard (1...5).contains(restfulness), ["cold", "comfortable", "warm"].contains(comfort), normalized.notes.utf16.count <= 500 else {
            throw MorningJournalFailure.unavailable("Choose a restfulness score and comfort level, and keep notes within 500 characters.")
        }
    }
}

struct MorningJournalRecord: Codable, Equatable, Sendable {
    let side: Side
    let date: String
    let fields: MorningJournalFields
    let timeZone: String
    let origin: String
    let createdAt: Double?
    let updatedAt: Double?
    let importedAt: Double?
    func validate() throws {
        try fields.validate()
        guard MorningJournalDates.valid(date), TimeZone(identifier: timeZone) != nil, ["free-sleep", "sleepypod"].contains(origin),
              [createdAt, updatedAt, importedAt].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 253_402_300_799_000 && $0.rounded() == $0 }) else {
            throw MorningJournalFailure.invalid
        }
    }
}

struct MorningJournalSelection: Codable, Equatable, Sendable {
    let side: Side
    let date: String
    let revision: String?
    let record: MorningJournalRecord?
    func validate(side: Side, date: String) throws {
        guard self.side == side, self.date == date, MorningJournalDates.valid(date),
              revision.map({ UUID(uuidString: $0) != nil }) ?? true,
              record == nil || revision != nil else { throw MorningJournalFailure.invalid }
        if let record {
            try record.validate()
            guard record.side == side, record.date == date else { throw MorningJournalFailure.invalid }
        }
    }
}

struct MorningJournalPage: Codable, Equatable, Sendable {
    struct Patterns: Codable, Equatable, Sendable {
        struct Cohort: Codable, Equatable, Sendable {
            struct Association: Codable, Equatable, Sendable {
                let habit: String
                let withCount: Int
                let withoutCount: Int
                let presenceDifferenceMinutes: Double
            }
            let source: String
            let timeZone: String?
            let status: String
            let matchedDates: Int
            let excludedDates: Int
            let associations: [Association]
        }
        let recentEntries: Int
        let averageRestfulness: Double?
        let warmCount: Int
        let coldCount: Int
        let cohorts: [Cohort]
        let note: String
    }
    let apiVersion: Int
    let side: Side
    let timeZone: String
    let deviceDate: String
    let from: String
    let through: String
    let selected: MorningJournalSelection
    let entries: [MorningJournalSelection]
    let patterns: Patterns

    /// Validate scope, calendar dates and source-separated summaries before showing editable data.
    func validate(side: Side, date: String?, days: Int) throws {
        guard apiVersion == 1, self.side == side, (1...90).contains(days), TimeZone(identifier: timeZone) != nil,
              MorningJournalDates.valid(deviceDate), through == (date ?? deviceDate), through <= deviceDate,
              from == max("1970-01-01", MorningJournalDates.shift(through, days: 1 - days) ?? ""),
              MorningJournalDates.localDate(through, timeZone: timeZone) != nil,
              entries.count <= 90, Set(entries.map(\.date)).count == entries.count,
              entries.map(\.date) == entries.map(\.date).sorted(by: >) else { throw MorningJournalFailure.invalid }
        try selected.validate(side: side, date: through)
        for entry in entries {
            try entry.validate(side: side, date: entry.date)
            guard entry.record != nil, entry.date >= from, entry.date <= through else { throw MorningJournalFailure.invalid }
        }
        if let entry = entries.first(where: { $0.date == through }), entry != selected { throw MorningJournalFailure.invalid }
        guard (0...7).contains(patterns.recentEntries), patterns.recentEntries <= entries.count,
              (0...patterns.recentEntries).contains(patterns.warmCount), (0...patterns.recentEntries).contains(patterns.coldCount),
              patterns.averageRestfulness.map({ $0.isFinite && (1...5).contains($0) }) ?? (patterns.recentEntries == 0),
              patterns.cohorts.count <= 2, Set(patterns.cohorts.map(\.source)).count == patterns.cohorts.count else { throw MorningJournalFailure.invalid }
        for cohort in patterns.cohorts {
            guard ["sleepypod", "free-sleep"].contains(cohort.source), ["ready", "unavailable", "not_imported", "too_many_records"].contains(cohort.status),
                  cohort.matchedDates >= 0, cohort.excludedDates >= 0, cohort.associations.count <= 3,
                  Set(cohort.associations.map(\.habit)).count == cohort.associations.count,
                  cohort.status == "ready" || cohort.associations.isEmpty else { throw MorningJournalFailure.invalid }
            if let zone = cohort.timeZone, TimeZone(identifier: zone) == nil { throw MorningJournalFailure.invalid }
            for association in cohort.associations {
                guard ["caffeine", "alcohol", "exercise"].contains(association.habit), association.withCount >= 5, association.withoutCount >= 5,
                      association.presenceDifferenceMinutes.isFinite else { throw MorningJournalFailure.invalid }
            }
        }
    }
}

struct MorningJournalWrite: Encodable, Sendable {
    let side: Side
    let date: String
    let expectedRevision: String?
    let fields: MorningJournalFields?
    private enum CodingKeys: String, CodingKey { case side, date, expectedRevision, fields }
    /// Explicit nulls carry both the original empty revision and content-only deletion semantics.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(side, forKey: .side); try container.encode(date, forKey: .date)
        try container.encode(expectedRevision, forKey: .expectedRevision); try container.encode(fields?.normalized, forKey: .fields)
    }
}

enum MorningJournalDates {
    static func valid(_ value: String) -> Bool { value >= "1970-01-01" && PersonalComfortDates.date(value) != nil }
    static func shift(_ value: String, days: Int) -> String? {
        guard let date = PersonalComfortDates.date(value) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        return calendar.date(byAdding: .day, value: days, to: date).map { key($0, timeZone: "GMT") }
    }
    static func key(_ date: Date, timeZone: String) -> String { formatter(timeZone).string(from: date) }
    static func localDate(_ value: String, timeZone: String) -> Date? {
        guard valid(value), let result = formatter(timeZone).date(from: value), key(result, timeZone: timeZone) == value else { return nil }
        return result
    }
    private static func formatter(_ timeZone: String) -> DateFormatter {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(identifier: timeZone) ?? .gmt
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false; return formatter
    }
}
