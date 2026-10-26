import Foundation
import Observation

@MainActor @Observable final class ImportedHistoryWorkspace {
    private(set) var client: (any ImportedHistoryClient)?
    private(set) var status: ImportedHistoryStatus?
    private(set) var records: [ImportedHistoryRecord] = []
    private(set) var applied: ImportedHistoryQuery?
    private(set) var nextCursor: String?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var stale = false
    private var generation = 0
    private var seenCursors: Set<String> = []
    var canLoadMore: Bool { nextCursor != nil && records.count < 5_000 && !busy && !stale }

    func configure(client: (any ImportedHistoryClient)?) {
        cancelPending(); self.client = client; status = nil; clearRecords()
    }
    func cancelPending() { generation += 1; busy = false }
    func clearRecords() {
        cancelPending(); records = []; applied = nil; nextCursor = nil; seenCursors = []; error = nil; stale = false
    }
    func loadStatus() async {
        guard !busy else { return }
        clearRecords(); status = nil
        guard let client else { error = "Connect to your Sleepypod controller to read imported history."; return }
        let operation = generation, owner = OwnerConnection.revision
        busy = true; defer { if generation == operation { busy = false } }
        do {
            let result = try await client.status(); try result.validate()
            guard current(operation, owner: owner) else { return }
            status = result
        } catch { if current(operation, owner: owner) { self.error = APIError.message(for: error) } }
    }
    func apply(side: Side, kind: ImportedHistoryKind, start: Date, end: Date) async {
        guard !busy, let snapshot = status?.snapshot else { return }
        clearRecords()
        do {
            let query = try ImportedHistoryQuery.days(snapshot: snapshot, side: side, kind: kind, from: start, through: end)
            await load(query, append: false)
        } catch { self.error = APIError.message(for: error) }
    }
    func loadMore() async {
        guard canLoadMore, var query = applied, let nextCursor else { return }
        query.cursor = nextCursor; await load(query, append: true)
    }
    /// Validate every page before publishing it; a new source discards all old cursors and rows.
    private func load(_ query: ImportedHistoryQuery, append: Bool) async {
        guard let client, !busy else { return }
        let operation = generation, owner = OwnerConnection.revision
        busy = true; error = nil; defer { if generation == operation { busy = false } }
        do {
            let page = try await client.page(query); try page.validate(for: query)
            guard current(operation, owner: owner) else { return }
            if append {
                guard !page.records.contains(where: { value in records.contains(where: { $0.id == value.id }) }),
                      page.nextCursor.map({ !seenCursors.contains($0) }) ?? true else {
                    throw ImportedHistoryFailure.invalid("The archive repeated a page. Apply the dates again before continuing.")
                }
                if let last = records.last, let first = page.records.first {
                    guard first.timestamp < last.timestamp || (first.timestamp == last.timestamp && first.sourceID < last.sourceID) else {
                        throw ImportedHistoryFailure.invalid("The archive page order changed. Apply the dates again.")
                    }
                }
            }
            records = append ? records + page.records : page.records
            applied = query; nextCursor = page.nextCursor; stale = false
            if let cursor = query.cursor { seenCursors.insert(cursor) }
        } catch {
            guard current(operation, owner: owner) else { return }
            if case ImportedHistoryFailure.changed = error { status = nil; records = []; applied = nil; nextCursor = nil; seenCursors = [] }
            self.error = APIError.message(for: error); stale = !records.isEmpty
        }
    }
    private func current(_ operation: Int, owner: [String]) -> Bool { generation == operation && owner == OwnerConnection.revision && !Task.isCancelled }
}

@MainActor @Observable final class ImportedPresenceWorkspace {
    private(set) var detail: ImportedHistoryDetail?
    private(set) var error: String?
    private(set) var busy = false
    private var generation = 0
    func invalidate() { generation += 1; busy = false; detail = nil }
    func load(client: any ImportedHistoryClient, snapshotID: String, record: ImportedPresenceRecord) async {
        guard !busy else { return }
        let operation = generation, owner = OwnerConnection.revision
        busy = true; detail = nil; error = nil; defer { if generation == operation { busy = false } }
        do {
            let result = try await client.presence(snapshotID: snapshotID, record: record)
            try result.validate(snapshotID: snapshotID, original: record)
            guard generation == operation, owner == OwnerConnection.revision, !Task.isCancelled else { return }
            detail = result
        } catch { if generation == operation, owner == OwnerConnection.revision { self.error = APIError.message(for: error) } }
    }
}
