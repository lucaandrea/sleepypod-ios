import CryptoKit
import Foundation

/// A past authenticated read, never a session, command, publication or alarm receipt.
struct PersonalOfflineLibrary: Codable, Equatable {
    var version = 1
    let session: HouseholdSession
    var recordings: [PersonalOfflineRecordings] = []
    var week: PersonalOfflineWeek?

    func validate(for connection: PersonalBedConnection, now: Int64) throws {
        try session.validate()
        guard version == 1, session == connection.session,
              recordings.count <= PersonalHistoryQuery.Kind.allCases.count,
              Set(recordings.map { $0.query.kind }).count == recordings.count,
              Set(recordings.flatMap(\.records).map(\.id)).count == recordings.reduce(0, { $0 + $1.records.count }),
              Set(recordings.map(\.attributionRevision)).count <= 1 else { throw HouseholdFailure.changedIdentity }
        try recordings.forEach { try $0.validate(for: session, now: now) }
        try week?.validate(for: session, now: now)
    }

    /// Credential changes and origin changes get different ciphertext namespaces.
    static func scope(_ connection: PersonalBedConnection) throws -> String {
        try connection.session.validate()
        guard try HouseholdHTTPClient.endpoint(connection.endpoint.absoluteString) == connection.endpoint,
              HouseholdValidation.secret(connection.token) else { throw HouseholdFailure.invalid }
        let fields = [connection.id.uuidString, connection.endpoint.absoluteString, connection.token] + connection.session.identity
        let encoded = try JSONEncoder().encode(fields)
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }

    static func validClock(_ value: Int64, now: Int64) -> Bool {
        PersonalHistoryQuery.validTime(now) && PersonalHistoryQuery.validTime(value) && value <= now
    }
}

struct PersonalOfflineRecordings: Codable, Equatable, Identifiable {
    static let capacity = 300
    let query: PersonalHistoryQuery
    let attributionRevision: Int
    var generatedAt: Int64
    var syncedAt: Int64
    var records: [PersonalHistoryRecord]
    var hasMore: Bool
    var id: String { query.kind.rawValue }

    func validate(for session: HouseholdSession, now: Int64) throws {
        try query.validate()
        guard session.capabilities.personalHistory, HouseholdValidation.revision(attributionRevision),
              PersonalOfflineLibrary.validClock(syncedAt, now: now),
              PersonalOfflineLibrary.validClock(generatedAt, now: now), query.endsAt <= syncedAt,
              records.count <= Self.capacity, Set(records.map(\.id)).count == records.count else { throw HouseholdFailure.invalid }
        var previous: Int64?
        for record in records {
            try record.validate(sleeperId: session.selfSleeperId)
            guard record.payload.kind == query.kind, query.overlaps(record), record.endsAt <= syncedAt,
                  previous.map({ record.startsAt <= $0 }) ?? true else { throw HouseholdFailure.invalid }
            previous = record.startsAt
        }
    }
}

struct PersonalOfflineWeek: Codable, Equatable {
    let syncedAt: Int64
    let sourceSide: Side
    let temperatureZones: [Side]
    let timeZone: String
    let revision: String
    let routines: [BedtimeRoutineSnapshot]
    let temperatureUnit: String

    init(review: PersonalRoutineReview, syncedAt: Int64, temperatureUnit: String = "F") {
        self.temperatureUnit = temperatureUnit
        self.syncedAt = syncedAt; sourceSide = review.sourceSide; temperatureZones = review.temperatureZones
        timeZone = review.timeZone; revision = review.liveRevision; routines = review.liveWeek
    }
    func validate(for session: HouseholdSession, now: Int64) throws {
        try PersonalRoutineWeek.validate(routines)
        guard ["F", "C"].contains(temperatureUnit), session.capabilities.personalRoutinePublication == true,
              PersonalOfflineLibrary.validClock(syncedAt, now: now),
              Set(temperatureZones) == Set(session.person.zones), !temperatureZones.isEmpty,
              Set(temperatureZones).count == temperatureZones.count, temperatureZones.contains(sourceSide),
              TimeZone(identifier: timeZone) != nil, BedtimeRoutineTime.validRevision(revision) else { throw HouseholdFailure.invalid }
    }
}
