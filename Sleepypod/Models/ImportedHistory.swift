import Foundation

struct ImportedHistorySemantics: Codable, Sendable {
    var access: String
    var purpose: String
    var quality: String
    var presence: String
    var vitals: String
    var hrv: String
    var movement: String
    var previewEvidence: Bool
    var automationInput: Bool
    func validate() throws {
        guard access == "read_only", purpose == "history_only", quality == "legacy_unqualified",
              presence == "bed_presence_not_sleep_stages", vitals == "five_minute_interval_start_averages",
              hrv == "original_estimator_definition_unverified", movement == "original_total_movement",
              !previewEvidence, !automationInput else { throw ImportedHistoryFailure.invalid("The archive's source definitions are not supported.") }
    }
}

enum ImportedHistoryKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case presence, vitals, movement
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}
struct ImportedHistoryBounds: Codable, Sendable {
    var records: Int
    var readableRecords: Int
    var firstAt: Double?
    var lastAt: Double?
    func validate() throws {
        guard records >= 0, records <= 9_007_199_254_740_991, readableRecords >= 0, readableRecords <= records,
              readableRecords == 0 ? firstAt == nil && lastAt == nil : firstAt != nil && lastAt != nil else {
            throw ImportedHistoryFailure.invalid("The archive's record counts are inconsistent.")
        }
        if let firstAt, let lastAt { try ImportedHistoryValidation.epoch(firstAt); try ImportedHistoryValidation.epoch(lastAt)
            guard firstAt <= lastAt else { throw ImportedHistoryFailure.invalid("The archive's date bounds are inconsistent.") }
        }
    }
}
struct ImportedHistorySideBounds: Codable, Sendable {
    var presence: ImportedHistoryBounds
    var vitals: ImportedHistoryBounds
    var movement: ImportedHistoryBounds
    subscript(_ kind: ImportedHistoryKind) -> ImportedHistoryBounds {
        switch kind {
        case .presence: presence
        case .vitals: vitals
        case .movement: movement
        }
    }
}
struct ImportedHistorySnapshot: Codable, Sendable {
    struct Sides: Codable, Sendable { var left: ImportedHistorySideBounds; var right: ImportedHistorySideBounds }
    var format: String
    var source: String
    var snapshotId: String
    var sourceSha256: String
    var timeZone: String
    var importedAt: Double
    var sides: Sides
    var unassignedRecords: Int
    func bounds(side: Side, kind: ImportedHistoryKind) -> ImportedHistoryBounds { (side == .left ? sides.left : sides.right)[kind] }
    func validate() throws {
        guard format == "sleepypod-imported-history/1", source == "free-sleep", TimeZone(identifier: timeZone) != nil,
              unassignedRecords >= 0, unassignedRecords <= 9_007_199_254_740_991, importedAt.rounded() == importedAt else { throw ImportedHistoryFailure.invalid("This imported archive format or timezone is unsupported.") }
        try ImportedHistoryValidation.digest(snapshotId); try ImportedHistoryValidation.digest(sourceSha256)
        try ImportedHistoryValidation.epoch(importedAt / 1000, wholeSeconds: false)
        for side in Side.allCases { for kind in ImportedHistoryKind.allCases { try bounds(side: side, kind: kind).validate() } }
    }
}
struct ImportedHistoryStatus: Codable, Sendable {
    enum State: String, Codable, Sendable { case ready, notImported = "not_imported", unavailable }
    var apiVersion: Int
    var status: State
    var snapshot: ImportedHistorySnapshot?
    var message: String
    var semantics: ImportedHistorySemantics
    func validate() throws {
        try semantics.validate()
        guard apiVersion == 1, (status == .ready) == (snapshot != nil) else { throw ImportedHistoryFailure.invalid("The archive's availability could not be verified.") }
        try snapshot?.validate()
    }
}
struct ImportedPresenceRecord: Codable, Equatable, Sendable {
    var id: Int
    var side: Side
    var enteredBedAt: Double
    var leftBedAt: Double
    var reportedDurationSeconds: Double?
    var exits: Double?
}
struct ImportedVitalsRecord: Codable, Equatable, Sendable {
    var id: Int
    var side: Side
    var timestamp: Double
    var heartRateBpm: Double?
    var hrvEstimateMs: Double?
    var breathingRatePerMinute: Double?
}
struct ImportedMovementRecord: Codable, Equatable, Sendable {
    var id: Int
    var side: Side
    var timestamp: Double
    var totalMovement: Double?
}
enum ImportedHistoryRecord: Decodable, Equatable, Sendable, Identifiable {
    case presence(ImportedPresenceRecord), vitals(ImportedVitalsRecord), movement(ImportedMovementRecord)
    enum CodingKeys: String, CodingKey { case kind }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ImportedHistoryKind.self, forKey: .kind) {
        case .presence: self = .presence(try ImportedPresenceRecord(from: decoder))
        case .vitals: self = .vitals(try ImportedVitalsRecord(from: decoder))
        case .movement: self = .movement(try ImportedMovementRecord(from: decoder))
        }
    }
    var kind: ImportedHistoryKind {
        switch self {
        case .presence: .presence
        case .vitals: .vitals
        case .movement: .movement
        }
    }
    var sourceID: Int {
        switch self {
        case .presence(let value): value.id
        case .vitals(let value): value.id
        case .movement(let value): value.id
        }
    }
    var id: String { "\(kind.rawValue)-\(sourceID)" }
    var side: Side {
        switch self {
        case .presence(let value): value.side
        case .vitals(let value): value.side
        case .movement(let value): value.side
        }
    }
    var timestamp: Double {
        switch self {
        case .presence(let value): value.enteredBedAt
        case .vitals(let value): value.timestamp
        case .movement(let value): value.timestamp
        }
    }
    func validate() throws {
        guard sourceID > 0, sourceID <= 9_007_199_254_740_991 else { throw ImportedHistoryFailure.invalid("An archive record has an invalid identity.") }
        try ImportedHistoryValidation.epoch(timestamp)
        if case .presence(let value) = self { try ImportedHistoryValidation.epoch(value.leftBedAt) }
    }
}
struct ImportedHistoryQuery: Equatable, Sendable {
    var snapshotID: String
    var side: Side
    var kind: ImportedHistoryKind
    var start: Date
    var end: Date
    var cursor: String?
    var limit = 100
    var parameters: [String: String] {
        let formatter = ISO8601DateFormatter()
        var result = ["snapshotId": snapshotID, "side": side.rawValue, "kind": kind.rawValue,
                      "startTime": formatter.string(from: start), "endTime": formatter.string(from: end), "limit": String(limit)]
        result["cursor"] = cursor
        return result
    }
    /// Convert inclusive source-calendar days to the API's half-open interval, preserving DST.
    static func days(snapshot: ImportedHistorySnapshot, side: Side, kind: ImportedHistoryKind, from start: Date, through end: Date) throws -> Self {
        guard let zone = TimeZone(identifier: snapshot.timeZone) else { throw ImportedHistoryFailure.invalid("The archive timezone is unavailable.") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        guard let until = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) else { throw ImportedHistoryFailure.invalid("Choose a valid end date.") }
        let result = Self(snapshotID: snapshot.snapshotId, side: side, kind: kind, start: calendar.startOfDay(for: start), end: until)
        try result.validate(); return result
    }
    func validate() throws {
        try ImportedHistoryValidation.digest(snapshotID)
        let duration = end.timeIntervalSince(start)
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, start.timeIntervalSince1970 >= 0, duration > 0, duration <= 90 * 86400, (1...500).contains(limit),
              cursor.map({ !$0.isEmpty && $0.count <= 2048 }) ?? true else { throw ImportedHistoryFailure.invalid("Choose dates after 1970 spanning at most 90 days. A daylight-saving change may require a shorter date range.") }
    }
}
struct ImportedHistoryPage: Decodable, Sendable {
    var apiVersion: Int
    var snapshotId: String
    var side: Side
    var kind: ImportedHistoryKind
    var records: [ImportedHistoryRecord]
    var nextCursor: String?
    var semantics: ImportedHistorySemantics
    func validate(for query: ImportedHistoryQuery) throws {
        try semantics.validate()
        guard apiVersion == 1, snapshotId == query.snapshotID, side == query.side, kind == query.kind,
              records.count <= query.limit, Set(records.map(\.id)).count == records.count,
              nextCursor.map({ !$0.isEmpty && $0.count <= 2048 && $0 != query.cursor }) ?? true else { throw ImportedHistoryFailure.invalid("This archive page does not match the selected source or filters. Reload the archive.") }
        for record in records {
            try record.validate()
            guard record.side == side, record.kind == kind else { throw ImportedHistoryFailure.invalid("The archive returned a record from another side or type.") }
            let lower = query.start.timeIntervalSince1970, upper = query.end.timeIntervalSince1970
            let belongs: Bool
            if case .presence(let value) = record { belongs = value.enteredBedAt < upper && value.leftBedAt > lower }
            else { belongs = record.timestamp >= lower && record.timestamp < upper }
            guard belongs else { throw ImportedHistoryFailure.invalid("The archive returned a record outside the selected dates.") }
        }
        for (newer, older) in zip(records, records.dropFirst()) {
            guard newer.timestamp > older.timestamp || (newer.timestamp == older.timestamp && newer.sourceID > older.sourceID) else {
                throw ImportedHistoryFailure.invalid("The archive page order changed. Reload before continuing.")
            }
        }
    }
}
struct ImportedHistoryIntervals: Decodable, Sendable {
    enum State: String, Decodable, Sendable { case available, unavailable, invalid, tooLarge = "too_large", unsupportedWindow = "unsupported_window" }
    var status: State
    var intervals: [[Double]]?
    var coveredSeconds: Double?
}
struct ImportedHistoryDetail: Decodable, Sendable {
    var apiVersion: Int
    var snapshotId: String
    var record: ImportedPresenceRecord
    var present: ImportedHistoryIntervals
    var absent: ImportedHistoryIntervals
    var rawPresentIntervals: String?
    var rawAbsentIntervals: String?
    var semantics: ImportedHistorySemantics
    func validate(snapshotID: String, original: ImportedPresenceRecord) throws {
        try semantics.validate(); try ImportedHistoryRecord.presence(record).validate()
        guard apiVersion == 1, snapshotId == snapshotID, record == original else { throw ImportedHistoryFailure.invalid("The presence record changed. Reload the archive before opening it again.") }
        for claim in [present, absent] {
            guard (claim.intervals?.count ?? 0) <= 10_000, claim.coveredSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw ImportedHistoryFailure.invalid("The presence intervals are not readable.") }
            if claim.status == .available {
                guard let intervals = claim.intervals, !intervals.isEmpty, claim.coveredSeconds != nil else { throw ImportedHistoryFailure.invalid("The presence intervals are incomplete.") }
                var previousEnd: Double?
                var covered: Double = 0
                for interval in intervals {
                    guard interval.count == 2 else { throw ImportedHistoryFailure.invalid("A presence interval is incomplete.") }
                    try ImportedHistoryValidation.epoch(interval[0]); try ImportedHistoryValidation.epoch(interval[1])
                    guard interval[0] < interval[1], interval[0] >= record.enteredBedAt, interval[1] <= record.leftBedAt,
                          previousEnd.map({ $0 < interval[0] }) ?? true else { throw ImportedHistoryFailure.invalid("The presence intervals are not a normalized record window.") }
                    covered += interval[1] - interval[0]; previousEnd = interval[1]
                }
                guard covered == claim.coveredSeconds else { throw ImportedHistoryFailure.invalid("The interval coverage does not match its normalized intervals.") }
            } else if claim.intervals != nil || claim.coveredSeconds != nil {
                throw ImportedHistoryFailure.invalid("Unavailable intervals cannot provide a measured duration.")
            }
        }
        for raw in [rawPresentIntervals, rawAbsentIntervals].compactMap({ $0 }) {
            guard raw.utf8.count <= 262_144 else { throw ImportedHistoryFailure.invalid("The original interval text exceeds the supported size.") }
        }
    }
}
enum ImportedHistoryFailure: Error, LocalizedError, Sendable {
    case invalid(String), changed, unavailable(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let message), .unavailable(let message): message
        case .changed: "The imported archive changed. Reload its source information before continuing."
        }
    }
}
enum ImportedHistoryValidation {
    static func digest(_ value: String) throws {
        guard value.count == 64, value.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw ImportedHistoryFailure.invalid("The archive source identity is invalid.") }
    }
    static func epoch(_ value: Double, wholeSeconds: Bool = true) throws {
        guard value.isFinite, value >= 0, value <= 253_402_300_799, !wholeSeconds || value.rounded() == value else { throw ImportedHistoryFailure.invalid("An archive timestamp is outside the supported range.") }
    }
}
