import Foundation
import Observation

struct AnalysisHistoryRecord: Identifiable, Sendable {
    let id: String
    let side: Side
    let start: Date
    let end: Date
    let archived: Bool
}

struct AnalysisArchiveData: Sendable {
    var presence: [AnalysisHistoryRecord] = []
    var vitals: [ImportedVitalsRecord] = []
    var movementCount = 0
}

/// Page the complete archive while retaining the original meaning of each record type.
enum AnalysisHistoryReader {
    static func archive(_ client: any ImportedHistoryClient, progress: @MainActor (Int, Int) -> Void) async throws -> [AnalysisHistoryRecord] {
        guard let snapshot = try await snapshot(client) else { return [] }
        return presence(try await read(client, snapshot: snapshot, kind: .presence, progress: progress))
    }

    static func all(_ client: any ImportedHistoryClient, progress: @MainActor (ImportedHistoryKind, Int, Int) -> Void) async throws -> AnalysisArchiveData {
        guard let snapshot = try await snapshot(client) else { return .init() }
        var result = AnalysisArchiveData()
        for kind in ImportedHistoryKind.allCases {
            let records = try await read(client, snapshot: snapshot, kind: kind) { count, total in progress(kind, count, total) }
            switch kind {
            case .presence: result.presence = presence(records)
            case .vitals: result.vitals = records.compactMap { if case .vitals(let value) = $0 { value } else { nil } }
            case .movement: result.movementCount = records.count
            }
        }
        return result
    }

    private static func snapshot(_ client: any ImportedHistoryClient) async throws -> ImportedHistorySnapshot? {
        let status = try await client.status(); try status.validate()
        if status.status == .unavailable { throw ImportedHistoryFailure.unavailable(status.message) }
        return status.snapshot
    }

    private static func presence(_ records: [ImportedHistoryRecord]) -> [AnalysisHistoryRecord] {
        records.compactMap { item in
            guard case .presence(let record) = item else { return nil }
            return .init(id: "archive-\(record.side.rawValue)-\(record.id)", side: record.side,
                         start: Date(timeIntervalSince1970: record.enteredBedAt), end: Date(timeIntervalSince1970: record.leftBedAt), archived: true)
        }
    }

    private static func read(_ client: any ImportedHistoryClient, snapshot: ImportedHistorySnapshot, kind: ImportedHistoryKind,
                             progress: @MainActor (Int, Int) -> Void) async throws -> [ImportedHistoryRecord] {
        let expected = Side.allCases.reduce(0) { $0 + snapshot.bounds(side: $1, kind: kind).readableRecords }
        guard expected <= 250_000 else { throw ImportedHistoryFailure.invalid("This archive is too large to load at once. Browse it by date in Imported history.") }
        var records: [String: ImportedHistoryRecord] = [:]
        for side in Side.allCases {
            let bounds = snapshot.bounds(side: side, kind: kind)
            guard let first = bounds.firstAt, let last = bounds.lastAt else { continue }
            var lower = Date(timeIntervalSince1970: max(0, first - 1))
            let upper = Date(timeIntervalSince1970: last + 1)
            while lower < upper {
                let end = min(upper, lower.addingTimeInterval(89 * 86400))
                var query = ImportedHistoryQuery(snapshotID: snapshot.snapshotId, side: side, kind: kind, start: lower, end: end)
                var cursors: Set<String> = []
                repeat {
                    try Task.checkCancellation(); try query.validate()
                    let page = try await client.page(query); try page.validate(for: query)
                    for record in page.records { records["\(side.rawValue)-\(record.sourceID)"] = record }
                    await progress(records.count, expected)
                    if let cursor = page.nextCursor {
                        guard !page.records.isEmpty, cursors.insert(cursor).inserted else {
                            throw ImportedHistoryFailure.invalid("The archive repeated a page. Reload history before continuing.")
                        }
                    }
                    query.cursor = page.nextCursor
                } while query.cursor != nil
                lower = end
            }
        }
        guard records.count == expected else { throw ImportedHistoryFailure.invalid("Only \(records.count) of \(expected) archived \(kind.rawValue) records could be read. Reload the archive to check the import.") }
        return records.values.sorted { $0.timestamp > $1.timestamp }
    }
}

@MainActor @Observable final class AnalysisHistoryWorkspace {
    private(set) var records: [AnalysisHistoryRecord] = []
    private(set) var currentRecords: [SleepRecord] = []
    private(set) var archive = AnalysisArchiveData()
    var totalRecordCount: Int { records.count + archive.vitals.count + archive.movementCount }
    private(set) var loading = false
    private(set) var progress = ""
    private(set) var errors: [String] = []
    private(set) var loaded = false
    private var generation = 0

    func cancel() { generation += 1; loading = false }
    func load(api: any SleepypodProtocol, archive: (any ImportedHistoryClient)?, now: Date = .now) async {
        cancel(); let operation = generation, owner = OwnerConnection.revision
        records = []; currentRecords = []; self.archive = .init(); errors = []; loaded = false; loading = true
        defer { if operation == generation { loading = false } }
        progress = "Reading Pod history…"
        do {
            let values = try await api.getSleepRecords(side: nil, start: Date(timeIntervalSince1970: 0), end: now)
            guard current(operation, owner) else { return }
            currentRecords = values.filter { Side(rawValue: $0.side) != nil && $0.enteredBedDate.timeIntervalSince1970 > 0 }
            records = currentRecords.compactMap { record in
                guard let side = Side(rawValue: record.side), let end = record.completedAt, end > record.enteredBedDate else { return nil }
                return .init(id: "pod-\(side.rawValue)-\(record.id)", side: side, start: record.enteredBedDate, end: end, archived: false)
            }
        } catch { if current(operation, owner) { errors.append("Pod history: \(APIError.message(for: error))") } }
        guard current(operation, owner) else { return }
        if let archive {
            do {
                let archived = try await AnalysisHistoryReader.all(archive) { kind, count, total in
                    if self.current(operation, owner) { self.progress = "Reading archive · \(count) of \(total) \(kind.rawValue) records" }
                }
                guard current(operation, owner) else { return }
                self.archive = archived
                records.append(contentsOf: archived.presence)
            } catch { if current(operation, owner) { errors.append("Imported history: \(APIError.message(for: error))") } }
        }
        guard current(operation, owner) else { return }
        records.sort { $0.start > $1.start }; loaded = true
    }
    private func current(_ operation: Int, _ owner: [String]) -> Bool {
        operation == generation && owner == OwnerConnection.revision && !Task.isCancelled
    }
}
