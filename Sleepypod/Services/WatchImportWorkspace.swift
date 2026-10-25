import Foundation
import Observation

@MainActor @Observable
final class WatchImportWorkspace {
    struct PreparedFile: Sendable {
        let url: URL
        let bytes: Int64
        var name: String { url.lastPathComponent }
        var size: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    }
    var file: PreparedFile?
    var preparing = false
    var uploading = false
    var progress = 0.0
    var error: String?
    var result: WatchImportResult?
    var period: WatchImportPeriod = .month
    let side: Side
    let client: any WatchReferenceClient
    private var operation: Task<Void, Never>?
    private var revision = 0
    var destination: String { client.destination }
    init(side: Side, client: any WatchReferenceClient) { self.side = side; self.client = client }

    // Keep a private file snapshot so the review and upload refer to the same bytes even if Files changes.
    func prepare(_ source: URL) async {
        guard !uploading else { return }
        revision += 1; let selectedRevision = revision
        preparing = true; error = nil; result = nil
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                _ = try WatchExportFile.validate(source)
                let folder = FileManager.default.temporaryDirectory.appending(path: "watch-import-\(UUID().uuidString)", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                do {
                    let destination = folder.appendingPathComponent(source.lastPathComponent)
                    try FileManager.default.copyItem(at: source, to: destination)
                    let bytes = try WatchExportFile.validate(destination)
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
                    return PreparedFile(url: destination, bytes: bytes)
                } catch { try? FileManager.default.removeItem(at: folder); throw error }
            }.value
            guard selectedRevision == revision, !Task.isCancelled else {
                try? FileManager.default.removeItem(at: prepared.url.deletingLastPathComponent()); preparing = false; return
            }
            removeFile(); file = prepared
        } catch { if selectedRevision == revision { self.error = error.localizedDescription } }
        if selectedRevision == revision { preparing = false }
    }
    func start() {
        guard !uploading, !preparing, let file else { return }
        uploading = true; progress = 0; result = nil; error = nil
        let selectedPeriod = period
        operation = Task { [self] in
            do {
                result = try await client.upload(file: file.url, side: side, period: selectedPeriod) { [weak self] value in
                    Task { @MainActor in self?.progress = value }
                }
                progress = 1
                removeFile()
            } catch {
                self.error = Task.isCancelled
                    ? "Upload cancelled. The Pod may already have imported some samples; retrying the same export is safe."
                    : error.localizedDescription + " Some samples may have imported. Existing records are skipped when you retry."
            }
            uploading = false; operation = nil
        }
    }
    func cancel() { operation?.cancel() }
    func cleanup() {
        revision += 1
        guard !uploading else { return }
        removeFile()
    }
    private func removeFile() {
        if let file { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        file = nil
    }
}
