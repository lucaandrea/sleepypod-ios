import Foundation
import FreeSleepKit

/// Keeps each recording type's most recently fetched range and the last read operating week.
/// A failed fetch cannot advance either timestamp; drafts and cursors never become saved controls.
struct PersonalOfflineLibraryStore {
    private let snapshots: PrivateSnapshotStore
    init(snapshots: PrivateSnapshotStore = .init(namespace: "personal-offline-library-v1")) { self.snapshots = snapshots }

    func read(connection: PersonalBedConnection, now: Int64) throws -> PersonalOfflineLibrary? {
        let scope = try PersonalOfflineLibrary.scope(connection)
        guard let value = try snapshots.read(PersonalOfflineLibrary.self, scope: scope) else { return nil }
        try value.validate(for: connection, now: now)
        return value
    }

    func save(_ page: PersonalHistoryPage, appending: Bool, connection: PersonalBedConnection, receivedAt: Int64) throws {
        try page.validate(for: connection.session, requested: page.query)
        var library = try existing(connection: connection, now: receivedAt)
        if library.recordings.contains(where: { $0.attributionRevision != page.attributionRevision }) {
            guard !appending else { throw HouseholdFailure.conflict }
            library.recordings = []
        }
        let index = library.recordings.firstIndex { $0.query.kind == page.query.kind }
        var saved: PersonalOfflineRecordings
        if appending {
            guard let index else { throw HouseholdFailure.conflict }
            saved = library.recordings[index]
            guard saved.query == page.query, saved.attributionRevision == page.attributionRevision,
                  saved.hasMore, saved.generatedAt <= page.generatedAt,
                  Set(saved.records.map(\.id)).isDisjoint(with: page.records.map(\.id)),
                  saved.records.last.map({ last in page.records.first.map { $0.startsAt <= last.startsAt } ?? true }) ?? true
            else { throw HouseholdFailure.conflict }
            let combined = saved.records + page.records
            saved.records = Array(combined.prefix(PersonalOfflineRecordings.capacity))
            saved.hasMore = combined.count > saved.records.count || page.nextCursor != nil
            saved.generatedAt = page.generatedAt; saved.syncedAt = receivedAt
        } else {
            saved = .init(query: page.query, attributionRevision: page.attributionRevision,
                          generatedAt: page.generatedAt, syncedAt: receivedAt, records: page.records, hasMore: page.nextCursor != nil)
        }
        if let index { library.recordings[index] = saved } else { library.recordings.append(saved) }
        try write(library, connection: connection, now: receivedAt)
    }

    func save(_ review: PersonalRoutineReview, connection: PersonalBedConnection, receivedAt: Int64, temperatureUnit: String = "F") throws {
        try review.validate(for: connection.session)
        var library = try existing(connection: connection, now: receivedAt)
        library.week = .init(review: review, syncedAt: receivedAt, temperatureUnit: temperatureUnit)
        try write(library, connection: connection, now: receivedAt)
    }

    func remove(connection: PersonalBedConnection) throws {
        try snapshots.remove(scope: PersonalOfflineLibrary.scope(connection))
    }

    private func existing(connection: PersonalBedConnection, now: Int64) throws -> PersonalOfflineLibrary {
        // A changed session is explicitly erased by the account coordinator before a new read.
        try read(connection: connection, now: now) ?? .init(session: connection.session)
    }
    private func write(_ value: PersonalOfflineLibrary, connection: PersonalBedConnection, now: Int64) throws {
        try value.validate(for: connection, now: now)
        try snapshots.write(value, scope: PersonalOfflineLibrary.scope(connection))
    }
}
