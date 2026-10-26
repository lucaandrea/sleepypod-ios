import Foundation
import Observation

@MainActor @Observable final class SystemStorageWorkspace {
    private(set) var report: SystemStorage?
    private(set) var receivedAt: Date?
    private(set) var loading = false
    private(set) var cleaning = false
    private(set) var error: String?
    private(set) var actionError: String?
    private(set) var result: StorageCleanupResult?
    private(set) var mustReload = false
    private let client: any SystemStorageClient
    init(client: any SystemStorageClient) { self.client = client }
    func load(now: Date = .now) async {
        guard !loading, !cleaning else { return }
        loading = true
        defer { loading = false }
        do {
            let value = try await client.report()
            guard !Task.isCancelled else { return }
            report = value; receivedAt = now; error = nil; mustReload = false
        } catch { if !Task.isCancelled { self.error = error.localizedDescription; mustReload = true } }
    }
    func selection(includeBackups: Bool, now: Date = .now) -> StorageCleanupSelection? {
        guard !loading, !cleaning, !mustReload, error == nil, let report, report.reclaimable.available,
              let receivedAt, (0...90).contains(now.timeIntervalSince(receivedAt)) else { return nil }
        let items = report.selected(includeBackups: includeBackups)
        return items.isEmpty ? nil : .init(includeBackups: includeBackups, items: items)
    }
    // Confirm the displayed candidate list is still current before asking Core to re-scan eligible leftovers.
    func clean(_ selected: StorageCleanupSelection) async {
        guard selection(includeBackups: selected.includeBackups) == selected else {
            actionError = "Storage changed or the report expired. Refresh and review the cleanup list again."
            return
        }
        cleaning = true; actionError = nil; result = nil
        do {
            result = try await client.clean(includeBackups: selected.includeBackups)
            cleaning = false
            await load()
        } catch {
            cleaning = false; mustReload = true
            actionError = "Cleanup result was not confirmed. Reload storage before trying again. \(error.localizedDescription)"
        }
    }
}
