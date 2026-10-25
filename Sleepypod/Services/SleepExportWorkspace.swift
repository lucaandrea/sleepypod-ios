import Foundation
import Observation

@MainActor @Observable
final class SleepExportWorkspace {
    var files: [RawSensorFile] = []
    var usage: RawDiskUsage?
    var error: String?
    var notice: String?
    var loading = false
    var preparing = false
    var shares: [URL] = []
    var activity = "Preparing file…"
    var canCancel: Bool { transfer != nil }
    private let api: any RawDataClient
    private var directory: URL?
    private var transfer: Task<Void, Never>?
    init(api: any RawDataClient) { self.api = api }
    func refresh() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            async let listed = api.files(); async let disk = api.usage()
            (files, usage) = try await (listed, disk)
        } catch { self.error = error.localizedDescription }
    }
    func delete(_ file: RawSensorFile) async {
        guard !preparing else { return }
        preparing = true; error = nil; notice = nil; activity = "Deleting sensor file…"
        defer { preparing = false }
        do {
            try await api.delete(file)
            notice = "\(file.name) deleted."
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func csv(_ content: [(name: String, text: String)]) {
        guard !preparing else { return }
        error = nil
        do {
            let folder = try makeDirectory()
            shares = try content.map { item in
                let url = folder.appendingPathComponent(item.name)
                try item.text.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
                return url
            }
        } catch { self.error = "The export could not be prepared: \(error.localizedDescription)"; cleanup() }
    }
    func download(_ file: RawSensorFile) { begin { folder in try await self.api.download(file, directory: folder) } }
    func archive(start: Date, end: Date) { begin { folder in try await self.api.archive(start: start, end: end, directory: folder) } }
    private func begin(_ action: @escaping @MainActor (URL) async throws -> URL) {
        guard !preparing else { return }
        preparing = true; error = nil; notice = nil
        activity = "Downloading file…"
        transfer = Task {
            defer { preparing = false; transfer = nil }
            do { let folder = try makeDirectory(); let url = try await action(folder); try Task.checkCancellation(); shares = [url] }
            catch is CancellationError { cleanup(); notice = "Download cancelled." }
            catch {
                cleanup()
                if Task.isCancelled { notice = "Download cancelled." } else { self.error = error.localizedDescription }
            }
        }
    }
    func cancel() { transfer?.cancel() }
    func cleanup() {
        shares = []
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
    private func makeDirectory() throws -> URL {
        cleanup()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sleepypod-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        directory = folder; return folder
    }
}
