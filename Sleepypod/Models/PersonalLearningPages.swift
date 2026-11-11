import Foundation

struct PersonalLearningArchivePage: Codable, Equatable, Sendable {
    struct Query: Codable, Equatable, Sendable { let before: String?; let limit: Int }
    let version: Int
    let generatedAt: Int64
    let scope: PersonalHistoryScope
    let interpretation: String
    let query: Query
    let archives: [PersonalLearningArchive]
    let nextCursor: String?
    static func decodeExact(_ data: Data) throws -> Self {
        try PersonalLearningDecoding.check(data, shape: .archives)
        return try JSONDecoder().decode(Self.self, from: data)
    }
    func validate(for session: HouseholdSession, before: String?, limit: Int = 20) throws {
        try PersonalLearningContract.envelope(version, generatedAt: generatedAt, interpretation: interpretation, scope: scope, session: session)
        guard (1...50).contains(limit), query == Query(before: before, limit: limit),
              before.map(HouseholdValidation.identifier) ?? true, archives.count <= limit,
              Set(archives.map(\.id)).count == archives.count,
              nextCursor == nil || (archives.count == limit && nextCursor == archives.last?.id) else { throw HouseholdFailure.invalid }
        try archives.forEach { try $0.validate(generatedAt: generatedAt) }
        for (previous, next) in zip(archives, archives.dropFirst()) {
            guard next.capturedAt < previous.capturedAt || (next.capturedAt == previous.capturedAt && next.id < previous.id) else { throw HouseholdFailure.invalid }
        }
    }
}

struct PersonalLearningRecordPage: Codable, Equatable, Sendable {
    struct Query: Codable, Equatable, Sendable { let archiveId: String; let after: Int; let limit: Int }
    let version: Int
    let generatedAt: Int64
    let scope: PersonalHistoryScope
    let interpretation: String
    let query: Query
    let archiveId: String
    let contentHash: String
    let records: [PersonalLearningRecord]
    let nextOrdinal: Int?
    static func decodeExact(_ data: Data) throws -> Self {
        try PersonalLearningDecoding.check(data, shape: .records)
        return try JSONDecoder().decode(Self.self, from: data)
    }
    func validate(for session: HouseholdSession, archive: PersonalLearningArchive, after: Int, limit: Int = 20) throws {
        try PersonalLearningContract.envelope(version, generatedAt: generatedAt, interpretation: interpretation, scope: scope, session: session)
        guard (1...50).contains(limit), (0...100_000).contains(after), query == Query(archiveId: archive.id, after: after, limit: limit),
              archiveId == archive.id, contentHash == archive.contentHash, records.count <= limit,
              generatedAt >= archive.capturedAt,
              Set(records.map(\.id)).count == records.count,
              nextOrdinal == nil || (records.count == limit && nextOrdinal == records.last?.ordinal && (nextOrdinal ?? 0) < archive.recordCount) else { throw HouseholdFailure.invalid }
        var previous = after
        var byteCount = 0
        for record in records {
            try record.validate()
            guard record.ordinal > previous, record.ordinal <= archive.recordCount else { throw HouseholdFailure.invalid }
            byteCount += record.payloadBytes
            guard byteCount <= archive.payloadBytes else { throw HouseholdFailure.invalid }
            previous = record.ordinal
        }
    }
}
