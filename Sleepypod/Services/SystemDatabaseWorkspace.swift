import Foundation
import Observation

@MainActor @Observable
final class SystemDatabaseWorkspace {
    private(set) var overview: SystemDatabaseOverview?
    private(set) var loading = false
    private(set) var checking = false
    private(set) var downloading = false
    private(set) var error: String?
    private(set) var integrityResult: [String: SystemDatabase.IntegrityRun]?
    private(set) var backupURL: URL?
    private let client: any SystemDatabaseClient
    private var revision = 0
    init(client: any SystemDatabaseClient) { self.client = client }
    func load(fresh: Bool = false) async {
        revision += 1; let requestRevision = revision
        loading = true; error = nil
        defer { if revision == requestRevision { loading = false } }
        do {
            let result = try await client.overview(fresh: fresh)
            guard !Task.isCancelled, revision == requestRevision else { return }
            overview = result
        } catch { if !Task.isCancelled, revision == requestRevision { self.error = error.localizedDescription } }
    }
    func checkIntegrity() async {
        guard !checking else { return }
        checking = true; error = nil; integrityResult = nil
        defer { checking = false }
        do {
            let result = try await client.integrity()
            guard !Task.isCancelled else { return }
            integrityResult = result
            await load(fresh: true)
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func downloadBackup() async {
        guard !downloading else { return }
        downloading = true; error = nil
        defer { downloading = false }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("database-export-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                let file = try await client.backup(directory: directory)
                guard !Task.isCancelled else { try? FileManager.default.removeItem(at: directory); return }
                removeBackup(); backupURL = file
            } catch { try? FileManager.default.removeItem(at: directory); throw error }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func removeBackup() {
        if let backupURL { try? FileManager.default.removeItem(at: backupURL.deletingLastPathComponent()) }
        backupURL = nil
    }
}

@MainActor @Observable
final class SystemDatabaseRowsWorkspace {
    private(set) var query: SystemDatabaseQuery
    private(set) var result: SystemDatabaseRows?
    private(set) var loading = false
    private(set) var error: String?
    private var revision = 0
    private let client: any SystemDatabaseClient
    init(query: SystemDatabaseQuery, client: any SystemDatabaseClient) { self.query = query; self.client = client }
    // Clear the previous page immediately so a changed filter cannot export old rows.
    func load(_ next: SystemDatabaseQuery? = nil) async {
        if let next { query = next }
        revision += 1; let requestRevision = revision; let requestedQuery = query
        result = nil; error = nil; loading = true
        defer { if revision == requestRevision { loading = false } }
        if let validation = requestedQuery.validation { error = validation; return }
        do {
            let response = try await client.rows(requestedQuery)
            guard !Task.isCancelled, revision == requestRevision else { return }
            result = response
        } catch { if !Task.isCancelled, revision == requestRevision { self.error = error.localizedDescription } }
    }
}
