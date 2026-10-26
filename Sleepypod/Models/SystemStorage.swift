import Foundation

struct SystemStorage: Decodable, Sendable {
    struct Volume: Decodable, Sendable { let totalBytes: Double; let usedBytes: Double; let availableBytes: Double; let usedPercent: Double }
    struct Segment: Decodable, Sendable, Identifiable {
        let key: String
        let bytes: Double
        var id: String { key }
        var title: String {
            switch key {
            case "rawArchive": "Raw sensor archive"
            case "app": "Sleepypod app"
            case "database": "Databases"
            case "swap": "Swap"
            case "reclaimable": "Reclaimable leftovers"
            case "other": "Other"
            default: key
            }
        }
    }
    struct RawHistory: Decodable, Sendable { let fileCount: Int; let oldest: String?; let newest: String?; let days: Double? }
    struct Reclaimable: Decodable, Sendable { let available: Bool; let totalBytes: Double; let items: [Item] }
    struct Item: Decodable, Sendable, Identifiable, Equatable {
        let path: String
        let bytes: Double
        let reason: String
        let kind: String
        var id: String { path }
        var shortPath: String { path.hasPrefix("/persistent/") ? String(path.dropFirst("/persistent/".count)) : path }
    }
    let persistent: Volume
    let prunerTargetPercent: Double
    let segments: [Segment]
    let rawHistory: RawHistory
    let reclaimable: Reclaimable
    func selected(includeBackups: Bool) -> [Item] { reclaimable.items.filter { includeBackups || $0.kind != "backup" } }
    var backupCount: Int { reclaimable.items.filter { $0.kind == "backup" }.count }
    static func bytes(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }
}
struct StorageCleanupResult: Decodable, Sendable { let freedBytes: Double; let removed: Int }
struct StorageCleanupSelection: Sendable, Equatable {
    let includeBackups: Bool
    let items: [SystemStorage.Item]
    var bytes: Double { items.reduce(0) { $0 + max(0, $1.bytes) } }
}
