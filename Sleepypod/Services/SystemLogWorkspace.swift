import Foundation
import Observation

@MainActor @Observable
final class SystemLogWorkspace {
    private(set) var sources: [LogSource] = []
    private(set) var query: SystemLogQuery
    private(set) var entries: [SystemLogEntry] = []
    private(set) var loading = false
    private(set) var loadingSources = false
    private(set) var sourcesError: String?
    private(set) var error: String?
    private(set) var receivedAt: Date?
    private(set) var hasOlder = false
    private let client: any SystemLogClient
    private var revision = 0
    init(unit: String? = nil, client: any SystemLogClient) { query = .init(unit: unit); self.client = client }
    func loadSources() async {
        guard !loadingSources else { return }
        loadingSources = true
        defer { loadingSources = false }
        do {
            let sources = try await client.sources()
            guard !Task.isCancelled else { return }
            self.sources = sources; sourcesError = nil
            if !sources.contains(where: { $0.unit == query.unit }) { setUnit(sources.first?.unit) }
        } catch { if !Task.isCancelled { sourcesError = error.localizedDescription } }
    }
    func setUnit(_ unit: String?) { var next = query; next.unit = unit; configure(next) }
    func setLevel(_ level: SystemLogLevel) { var next = query; next.level = level; configure(next) }
    func setLimit(_ limit: Int) { var next = query; next.lines = limit; configure(next) }
    // Invalidate immediately when a filter changes, before a new async fetch begins.
    private func configure(_ next: SystemLogQuery) {
        guard next != query else { return }
        revision += 1; query = next; entries = []; error = nil; receivedAt = nil; hasOlder = false; loading = false
    }
    func load() async {
        guard query.unit != nil else { return }
        revision += 1; let requested = revision; let query = query
        loading = true; error = nil
        defer { if revision == requested { loading = false } }
        do {
            let page = try await client.page(query)
            guard !Task.isCancelled, revision == requested else { return }
            entries = page.lines.enumerated().map { SystemLogEntry(raw: $0.element, index: $0.offset, floor: query.level) }
            receivedAt = .now; hasOlder = page.nextCursor != nil
        } catch { if !Task.isCancelled, revision == requested { self.error = error.localizedDescription } }
    }
    func filtered(_ text: String) -> [SystemLogEntry] {
        let search = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? entries : entries.filter { $0.raw.localizedCaseInsensitiveContains(search) }
    }
    func export(_ text: String) -> String { filtered(text).map(\.raw).joined(separator: "\n") }
}
