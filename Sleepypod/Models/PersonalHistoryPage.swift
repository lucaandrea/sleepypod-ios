import Foundation

struct PersonalHistoryPage: Codable, Equatable, Sendable {
    let version: Int
    let scope: PersonalHistoryScope
    let attributionRevision: Int
    let generatedAt: Int64
    let source: String
    let interpretation: String
    let query: PersonalHistoryQuery
    let intervalSelection: String
    let records: [PersonalHistoryRecord]
    let nextCursor: String?

    static func decodeExact(_ data: Data) throws -> Self {
        try PersonalHistoryDecoding.check(data, detail: false)
        return try JSONDecoder().decode(Self.self, from: data)
    }
    func validate(for session: HouseholdSession, requested: PersonalHistoryQuery) throws {
        try PersonalHistoryDecoding.envelope(version: version, attribution: attributionRevision, generatedAt: generatedAt, source: source, interpretation: interpretation)
        try scope.validate(for: session); try query.validate(); try requested.validate()
        guard query == requested, intervalSelection == "overlap_full_records", records.count <= query.limit,
              Set(records.map(\.id)).count == records.count else { throw HouseholdFailure.invalid }
        if let nextCursor {
            guard !nextCursor.isEmpty, nextCursor.utf16.count <= 4_096, records.count == query.limit else { throw HouseholdFailure.invalid }
        }
        var previousStart: Int64?
        for record in records {
            try record.validate(sleeperId: scope.sleeperId)
            guard record.payload.kind == query.kind, query.overlaps(record),
                  previousStart.map({ record.startsAt <= $0 }) ?? true else { throw HouseholdFailure.invalid }
            previousStart = record.startsAt
        }
    }
}
