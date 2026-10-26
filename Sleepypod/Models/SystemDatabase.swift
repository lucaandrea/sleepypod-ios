import Foundation

struct SystemDatabaseOverview: Decodable, Sendable {
    struct Disk: Decodable, Sendable { let totalBytes: Double; let availableBytes: Double }
    let at: Double
    let hoursFrom: Double
    let dataDir: String
    let disk: Disk?
    let lastBackupAt: Double?
    let occupiedHours: [Int]
    let databases: [SystemDatabase]
    var date: Date { Date(timeIntervalSince1970: at / 1000) }
    var totalBytes: Double { databases.reduce(0) { $0 + $1.fileBytes + $1.walBytes } }
}

struct SystemDatabase: Decodable, Sendable, Identifiable {
    enum Key: String, Codable, Sendable, CaseIterable, Identifiable {
        case sleepypod, biometrics
        var id: String { rawValue }
    }
    struct IntegrityRun: Decodable, Sendable {
        let status: String
        let checkedAt: String?
        let latencyMs: Double
        let error: String?
    }
    struct Integrity: Decodable, Sendable { let scheduled: IntegrityRun?; let manual: IntegrityRun? }
    struct Migrations: Decodable, Sendable {
        let applied: Int
        let known: Int
        let latestTag: String?
        let appliedTag: String?
        var note: String {
            if known == 0 { return "Migration journal not found" }
            if applied < known { return "\(known - applied) migrations pending" }
            if applied > known { return "\(applied - known) migrations applied by another build" }
            return appliedTag ?? latestTag ?? "Up to date"
        }
    }
    let key: Key
    let path: String
    let fileBytes: Double
    let walBytes: Double
    let pageSize: Double
    let freePages: Double
    let walAutocheckpoint: Double
    let error: String?
    let integrity: Integrity
    let migrations: Migrations
    let tables: [Table]
    var id: Key { key }
    struct Table: Decodable, Sendable, Identifiable {
        struct Retention: Decodable, Sendable { let days: Double; let by: String }
        let name: String
        let rows: Int
        let bytes: Double
        let timeColumn: String?
        let timeInMs: Bool
        let lastWriteAt: Double?
        let oldestAt: Double?
        let hourly: [Int]
        let rows24h: Int
        let retention: Retention?
        var id: String { name }
        // Update timestamps count touches, so they cannot estimate inserted bytes.
        var dailyGrowth: Double {
            guard rows > 0, !["updated_at", "last_updated", "last_checked"].contains(timeColumn ?? "") else { return 0 }
            return Double(rows24h) * bytes / Double(rows)
        }
        func projectedBytes(after days: Double) -> Double {
            guard let retention else { return bytes + dailyGrowth * days }
            let steady = dailyGrowth * retention.days
            if bytes <= steady { return min(steady, bytes + dailyGrowth * days) }
            guard retention.days > 0 else { return steady }
            return bytes + (steady - bytes) * min(1, days / retention.days)
        }
        func missingHour(_ hour: Int, occupied: Set<Int>) -> Bool {
            ["vitals", "vitals_quality"].contains(name) && hourly.indices.contains(hour) && hourly[hour] == 0 && occupied.contains(hour)
        }
    }
}

struct SystemDatabaseRows: Decodable, Sendable {
    enum Cell: Decodable, Sendable, Equatable {
        case null, text(String), number(Double)
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let text = try? container.decode(String.self) { self = .text(text) }
            else { self = .number(try container.decode(Double.self)) }
        }
        var display: String {
            switch self {
            case .null: return "NULL"
            case .text(let value): return value
            case .number(let value): return value.formatted(.number.grouping(.never).precision(.fractionLength(0...12)))
            }
        }
        var csv: String {
            switch self {
            case .null: return ""
            case .number(let value): return String(value)
            case .text(let value): return SystemDatabaseRows.csvText(value)
            }
        }
    }
    let columns: [String]
    let timeColumn: String?
    let rows: [[Cell]]
    let total: Int
    var csv: String {
        ([columns.map(Self.csvText).joined(separator: ",")] + rows.map { $0.map(\.csv).joined(separator: ",") }).joined(separator: "\r\n")
    }
    // Quote text and neutralize spreadsheet formulas while preserving numeric cells.
    static func csvText(_ value: String) -> String {
        let leading = value.trimmingCharacters(in: .whitespacesAndNewlines).first
        let text = leading.map { "=+-@".contains($0) } == true ? "'" + value : value
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

struct SystemDatabaseQuery: Equatable, Sendable {
    let database: SystemDatabase.Key
    let table: String
    var column: String?
    var value: String?
    var offset = 0
    var limit = 10
    var validation: String? {
        if table.isEmpty || table.count > 128 { return "Choose a valid table." }
        if let column, column.isEmpty || column.count > 128 { return "Choose a valid filter column." }
        if (column == nil) != (value == nil) { return "A filter needs both a column and a value." }
        if let value, value.count > 256 { return "Filter values can contain up to 256 characters." }
        if offset < 0 || !(1...100).contains(limit) { return "Choose a valid page size." }
        return nil
    }
    var parameters: [String: String] {
        var result = ["db": database.rawValue, "table": table, "offset": String(offset), "limit": String(limit)]
        result["column"] = column; result["value"] = value
        return result
    }
}

struct SystemDatabaseOutlook {
    struct Sample: Identifiable {
        let day: Double
        let bytes: Double
        var id: Double { day }
    }
    let samples: [Sample]
    let fillDays: Int?
    let availableBytes: Double?
    let growingPerDay: Double
    init(tables: [SystemDatabase.Table], availableBytes: Double?) {
        self.availableBytes = availableBytes
        growingPerDay = tables.filter { $0.retention == nil }.reduce(0) { $0 + $1.dailyGrowth }
        let current = tables.reduce(0) { $0 + $1.bytes }
        func total(_ days: Double) -> Double { tables.reduce(0) { $0 + $1.projectedBytes(after: days) } }
        fillDays = availableBytes.flatMap { available in (0...3650).first { total(Double($0)) >= current + available } }
        let horizon = fillDays.map { max(60, Double($0) * 1.15) } ?? 365
        samples = (0...60).map { let day = Double($0) * horizon / 60; return Sample(day: day, bytes: total(day)) }
    }
}
