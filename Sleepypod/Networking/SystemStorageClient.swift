import Foundation

protocol SystemStorageClient: Sendable {
    func report() async throws -> SystemStorage
    func clean(includeBackups: Bool) async throws -> StorageCleanupResult
}
struct CoreSystemStorageClient: SystemStorageClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient {
        get throws { guard let transport else { throw APIError.noBaseURL }; return transport }
    }
    func report() async throws -> SystemStorage { try await client.get("system/storage") }
    func clean(includeBackups: Bool) async throws -> StorageCleanupResult {
        try await client.post("system/storage/free", body: ["includeDbBackups": includeBackups], returning: StorageCleanupResult.self)
    }
}
actor DemoSystemStorageClient: SystemStorageClient {
    private var items: [SystemStorage.Item] = [
        .init(path: "/persistent/sleepypod-releases/demo-old", bytes: 270_000_000, reason: "Simulated inactive release", kind: "release"),
        .init(path: "/persistent/sleepypod-temp/demo-install", bytes: 90_000_000, reason: "Simulated installation leftovers", kind: "temp"),
        .init(path: "/persistent/backups/demo-old.db", bytes: 40_000_000, reason: "Simulated old database backup; a newer backup is retained", kind: "backup")
    ]
    func report() -> SystemStorage {
        let reclaimable = items.reduce(0) { $0 + $1.bytes }
        let used = 5_000_000_000 + reclaimable
        return .init(persistent: .init(totalBytes: 8_000_000_000, usedBytes: used, availableBytes: 8_000_000_000 - used, usedPercent: used / 8_000_000_000 * 100), prunerTargetPercent: 75,
                     segments: [.init(key: "rawArchive", bytes: 3_000_000_000), .init(key: "app", bytes: 800_000_000), .init(key: "database", bytes: 300_000_000), .init(key: "swap", bytes: 500_000_000), .init(key: "reclaimable", bytes: reclaimable), .init(key: "other", bytes: 400_000_000)],
                     rawHistory: .init(fileCount: 42, oldest: Date.now.addingTimeInterval(-21 * 86400).ISO8601Format(), newest: Date.now.ISO8601Format(), days: 21),
                     reclaimable: .init(available: true, totalBytes: reclaimable, items: items))
    }
    func clean(includeBackups: Bool) -> StorageCleanupResult {
        let removed = items.filter { includeBackups || $0.kind != "backup" }
        items.removeAll { includeBackups || $0.kind != "backup" }
        return .init(freedBytes: removed.reduce(0) { $0 + $1.bytes }, removed: removed.count)
    }
}
