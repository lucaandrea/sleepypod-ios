import Foundation
import Observation

/// Private recording bodies live only in this scope-bound, in-memory reader.
@MainActor @Observable final class PersonalHistoryWorkspace {
    enum Window: Int, CaseIterable { case week = 7, month = 30, quarter = 90 }
    let connection: PersonalBedConnection
    var kind: PersonalHistoryQuery.Kind = .presence { didSet { if kind != oldValue { discard() } } }
    var window: Window = .month { didSet { if window != oldValue { discard() } } }
    private(set) var query: PersonalHistoryQuery?
    private(set) var records: [PersonalHistoryRecord] = []
    private(set) var nextCursor: String?
    private(set) var attributionRevision: Int?
    private(set) var generatedAt: Int64?
    private(set) var detail: PersonalHistoryDetail?
    private(set) var loaded = false
    private(set) var busy = false
    private(set) var error: String?
    private(set) var isInvalidated = false
    private let client: any PersonalHistoryTransport
    private let permitted: @MainActor () -> Bool
    private let revoked: @MainActor () -> Void
    private let pageSize: Int
    private let clock: @MainActor () -> Int64
    private var generation = 0
    private var recordIds: Set<String> = []
    private var usedCursors: Set<String> = []

    init(connection: PersonalBedConnection, client: any PersonalHistoryTransport, pageSize: Int = 30,
         permitted: @escaping @MainActor () -> Bool = { true }, revoked: @escaping @MainActor () -> Void = {},
         now: @escaping @MainActor () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.pageSize = pageSize; self.connection = connection; self.client = client; self.permitted = permitted; self.revoked = revoked; clock = now
    }
    var enabled: Bool { !isInvalidated && permitted() && connection.session.capabilities.personalHistory }
    var canLoadMore: Bool { enabled && loaded && !busy && nextCursor != nil }
    func invalidate() { isInvalidated = true; discard() }
    func suspend() { discard() }
    func clearDetail() { generation += 1; detail = nil; busy = false }

    private func discard() {
        generation += 1; query = nil; records = []; nextCursor = nil; attributionRevision = nil; generatedAt = nil
        detail = nil; loaded = false; busy = false; error = nil; recordIds = []; usedCursors = []
    }
    func refresh() async {
        guard enabled, !busy else { return }
        discard()
        let operation = generation
        busy = true
        defer { if operation == generation { busy = false } }
        do {
            let end = clock()
            guard PersonalHistoryQuery.validTime(end), end >= Int64(window.rawValue) * 86_400_000 else { throw HouseholdFailure.invalid }
            let requested = PersonalHistoryQuery(startsAt: end - Int64(window.rawValue) * 86_400_000, endsAt: end, kind: kind, limit: pageSize)
            try requested.validate()
            let session = try await freshSession(operation)
            let page = try await client.page(requested, cursor: nil)
            try check(operation); try page.validate(for: session, requested: requested)
            query = requested; records = page.records; recordIds = Set(page.records.map(\.id))
            nextCursor = page.nextCursor; attributionRevision = page.attributionRevision; generatedAt = page.generatedAt; loaded = true
        } catch { fail(error, operation: operation) }
    }

    /// Every page belongs to the original person, range and attribution snapshot.
    func loadMore() async {
        guard canLoadMore, let query, let cursor = nextCursor, let attributionRevision else { return }
        let operation = generation
        busy = true; error = nil
        defer { if operation == generation { busy = false } }
        do {
            guard usedCursors.insert(cursor).inserted else { throw HouseholdFailure.conflict }
            let session = try await freshSession(operation)
            let page = try await client.page(query, cursor: cursor)
            try check(operation); try page.validate(for: session, requested: query)
            guard page.attributionRevision == attributionRevision,
                  recordIds.isDisjoint(with: page.records.map(\.id)),
                  page.nextCursor.map({ !usedCursors.contains($0) }) ?? true,
                  records.last.map({ last in page.records.first.map { $0.startsAt <= last.startsAt } ?? true }) ?? true
            else { throw HouseholdFailure.conflict }
            records.append(contentsOf: page.records); recordIds.formUnion(page.records.map(\.id))
            nextCursor = page.nextCursor; generatedAt = page.generatedAt
        } catch { fail(error, operation: operation) }
    }

    /// Detail reads reauthorize even when the same record was just displayed in a page.
    func loadDetail(_ identifier: String) async {
        guard enabled, !busy, let recordId = UUID(uuidString: identifier) else { return }
        let operation = generation, expectedRecord = records.first { $0.id == identifier }, expectedAttribution = attributionRevision
        busy = true; error = nil; detail = nil
        defer { if operation == generation { busy = false } }
        do {
            let session = try await freshSession(operation)
            let result = try await client.detail(recordId)
            try check(operation); try result.validate(for: session)
            guard result.record.id == identifier,
                  expectedAttribution.map({ $0 == result.attributionRevision }) ?? true,
                  expectedRecord.map({ $0 == result.record }) ?? true else { throw HouseholdFailure.conflict }
            detail = result
        } catch { fail(error, operation: operation) }
    }
    private func freshSession(_ operation: Int) async throws -> HouseholdSession {
        let value = try await client.session()
        try check(operation); try value.validate()
        guard value == connection.session else { throw HouseholdFailure.changedIdentity }
        guard value.capabilities.personalHistory else { throw HouseholdFailure.unavailable }
        return value
    }
    private func check(_ operation: Int) throws {
        guard enabled, operation == generation, !Task.isCancelled else { throw HouseholdFailure.changedIdentity }
    }
    private func fail(_ failure: Error, operation: Int) {
        guard operation == generation else { return }
        discard()
        switch failure as? HouseholdFailure {
        case .authentication:
            isInvalidated = true; revoked()
            error = "This personal connection is unavailable or revoked. Reconnect before loading recordings."
        case .changedIdentity:
            isInvalidated = true
            error = "Your account or recording access changed. Previous records have been hidden. Refresh your personal account."
        case .conflict:
            error = "The recording snapshot changed. Refresh to start a new view."
        case .unavailable, .forbidden:
            error = "Recordings are unavailable for this personal account. Refresh your account before continuing."
        case .rateLimited:
            error = "Too many history requests. Wait before refreshing."
        case .uncertain:
            error = "The recordings could not be loaded. Refresh to try again."
        default:
            error = "The recording response could not be verified. Refresh before continuing."
        }
    }
}
