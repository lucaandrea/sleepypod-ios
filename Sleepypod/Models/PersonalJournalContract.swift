import Foundation

enum PersonalJournalContract {
    static let interpretation = "personal_self_report_not_sleep_measurement"
    static func instant(_ value: Int64) -> Bool { (0...253_402_300_799_000).contains(value) }
    static func zone(_ value: String) -> Bool { !value.isEmpty && value.utf16.count <= 100 && TimeZone(identifier: value) != nil }
    static func envelope(version: Int, generatedAt: Int64, interpretation: String, scope: PersonalHistoryScope, session: HouseholdSession) throws {
        guard version == 1, instant(generatedAt), interpretation == Self.interpretation else { throw HouseholdFailure.invalid }
        try scope.validate(for: session)
    }
}

struct PersonalJournalRecord: Codable, Equatable, Sendable {
    let date: String
    let timeZone: String
    let createdAt: Int64
    let updatedAt: Int64
    let fields: MorningJournalFields
}

struct PersonalJournalSelection: Codable, Equatable, Sendable {
    let date: String
    let revision: String?
    let timeZone: String?
    let record: PersonalJournalRecord?
    func validate(generatedAt: Int64) throws {
        guard MorningJournalDates.valid(date), (revision == nil) == (timeZone == nil),
              revision.map(HouseholdValidation.identifier) ?? true,
              timeZone.map(PersonalJournalContract.zone) ?? true else { throw HouseholdFailure.invalid }
        if let record {
            guard revision != nil, record.date == date, record.timeZone == timeZone,
                  PersonalJournalContract.instant(record.createdAt), record.updatedAt >= record.createdAt,
                  record.updatedAt <= generatedAt else { throw HouseholdFailure.invalid }
            try record.fields.validate()
            try record.fields.context?.validate(date: date, timeZone: record.timeZone, now: Date(timeIntervalSince1970: Double(generatedAt) / 1000))
        }
    }
}

struct PersonalJournalPage: Codable, Equatable, Sendable {
    struct Query: Codable, Equatable, Sendable { let date: String }
    let version: Int
    let generatedAt: Int64
    let scope: PersonalHistoryScope
    let interpretation: String
    let currentTimeZone: String
    let query: Query
    let entries: [PersonalJournalSelection]
    static func decodeExact(_ data: Data) throws -> Self {
        try PersonalJournalDecoding.check(data, receipt: false)
        return try JSONDecoder().decode(Self.self, from: data)
    }
    func validate(for session: HouseholdSession, date: String) throws {
        try PersonalJournalContract.envelope(version: version, generatedAt: generatedAt, interpretation: interpretation, scope: scope, session: session)
        guard PersonalJournalContract.zone(currentTimeZone), query.date == date, entries.count == 1,
              entries[0].date == date else { throw HouseholdFailure.invalid }
        try entries[0].validate(generatedAt: generatedAt)
    }
    var today: String { MorningJournalDates.key(Date(timeIntervalSince1970: Double(generatedAt) / 1000), timeZone: currentTimeZone) }
}

struct PersonalJournalReceipt: Codable, Equatable, Sendable {
    let requestId: String
    let date: String
    let revision: String
    let timeZone: String
    let savedAt: Int64
    let outcome: String
    func validate(generatedAt: Int64) throws {
        guard [requestId, revision].allSatisfy(HouseholdValidation.identifier), MorningJournalDates.valid(date),
              PersonalJournalContract.zone(timeZone), PersonalJournalContract.instant(savedAt), savedAt <= generatedAt,
              ["saved", "deleted"].contains(outcome) else { throw HouseholdFailure.invalid }
    }
}

struct PersonalJournalResult: Codable, Equatable, Sendable {
    let version: Int
    let generatedAt: Int64
    let scope: PersonalHistoryScope
    let interpretation: String
    let receipt: PersonalJournalReceipt?
    static func decodeExact(_ data: Data) throws -> Self {
        try PersonalJournalDecoding.check(data, receipt: true)
        return try JSONDecoder().decode(Self.self, from: data)
    }
    func validate(for session: HouseholdSession) throws {
        try PersonalJournalContract.envelope(version: version, generatedAt: generatedAt, interpretation: interpretation, scope: scope, session: session)
        try receipt?.validate(generatedAt: generatedAt)
    }
}

struct PersonalJournalWrite: Encodable, Sendable {
    let requestId: String
    let expectedSessionRevision: Int
    let expectedAssignmentRevision: Int
    let date: String
    let expectedRevision: String?
    let expectedTimeZone: String
    let fields: MorningJournalFields?
    enum CodingKeys: String, CodingKey {
        case requestId, expectedSessionRevision, expectedAssignmentRevision, date, expectedRevision, expectedTimeZone, fields
    }
    func validate() throws {
        guard HouseholdValidation.identifier(requestId), HouseholdValidation.revision(expectedSessionRevision),
              HouseholdValidation.revision(expectedAssignmentRevision), MorningJournalDates.valid(date),
              expectedRevision.map(HouseholdValidation.identifier) ?? true,
              PersonalJournalContract.zone(expectedTimeZone) else { throw HouseholdFailure.invalid }
        try fields?.validate()
    }
    // Null is part of the API: missing revision and deliberate deletion must not be omitted.
    func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(requestId, forKey: .requestId)
        try values.encode(expectedSessionRevision, forKey: .expectedSessionRevision)
        try values.encode(expectedAssignmentRevision, forKey: .expectedAssignmentRevision)
        try values.encode(date, forKey: .date)
        try values.encode(expectedRevision, forKey: .expectedRevision)
        try values.encode(expectedTimeZone, forKey: .expectedTimeZone)
        try values.encode(fields, forKey: .fields)
    }
}
