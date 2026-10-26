import Foundation
import Observation

@MainActor @Observable final class WaveformSelectionWorkspace {
    let client: any BiometricDatasetsServing
    let draft: WaveformDatasetDraft
    private(set) var admission: ReplayAdmission?
    private(set) var admissionAt: Date?
    private(set) var admissionError: String?
    private(set) var refreshingAdmission = false
    private(set) var sources: InspectedRawPage?
    private(set) var sourceCursor: String?
    private(set) var sourceCohortId: String?
    private(set) var loadingSources = false
    private(set) var sourceError: String?
    private(set) var scanning = false
    private(set) var scanCursor: String?
    private(set) var scanDone = false
    private(set) var scanNotice: String?
    private(set) var scanError: String?
    private var sourceRequest = UUID()
    init(parent: BiometricDataset, client: any BiometricDatasetsServing) { draft = .init(parent: parent); self.client = client }
    func canInspect(at now: Date = .now) -> Bool {
        guard !scanning, !scanDone, admission?.configured == true, admission?.admitted == true, admissionError == nil, let admissionAt else { return false }
        return (0...15).contains(now.timeIntervalSince(admissionAt))
    }
    func refreshAdmission() async {
        guard !refreshingAdmission else { return }; refreshingAdmission = true
        defer { refreshingAdmission = false }
        do {
            let value = try await client.replayAdmission()
            guard !Task.isCancelled else { return }
            admission = value; admissionAt = .now; admissionError = nil
        } catch { if !Task.isCancelled { admissionError = error.localizedDescription } }
    }
    /// New night/page reads supersede old replies without replacing a newer selection.
    func loadSources(cohort: BiometricDatasetManifest.Cohort, cursor: String? = nil) async {
        let request = UUID(); sourceRequest = request
        loadingSources = true; sourceError = nil
        if sourceCohortId != cohort.cohortId { sources = nil; sourceCursor = nil }
        sourceCohortId = cohort.cohortId
        defer { if sourceRequest == request { loadingSources = false } }
        do {
            guard draft.parent.manifest.splitProtocol.assignments.contains(cohort) else { throw WaveformInput.failure("Select a night from the frozen parent.") }
            let page = try await client.rawSources(startMs: max(0, cohort.startMs - 300000), endMs: cohort.endMs, cursor: cursor)
            guard !Task.isCancelled, request == sourceRequest else { return }
            let advancing = page.nextCursor.map { next in BiometricBacktestInput.isHash(next) && (cursor.map { next > $0 } ?? true) } ?? true
            guard page.items.count <= 50, page.items.allSatisfy(\.validIdentity), advancing,
                  Set(page.items.map(\.id)).count == page.items.count,
                  page.items.allSatisfy({ source in cursor.map { source.id > $0 } ?? true }),
                  page.nextCursor.map({ $0 == page.items.last?.id }) ?? true else {
                throw WaveformInput.failure("The archive page returned inconsistent identities or a nonadvancing cursor.")
            }
            sources = page; sourceCursor = cursor
        } catch { if !Task.isCancelled, request == sourceRequest { sourceError = error.localizedDescription } }
    }
    func inspectNext(cohort: BiometricDatasetManifest.Cohort) async {
        guard canInspect() else { return }; scanning = true; scanError = nil; scanNotice = nil
        let previous = scanCursor
        defer { scanning = false }
        do {
            let result = try await client.inspectRaw(afterName: previous).checked(after: previous)
            guard !Task.isCancelled else { return }
            switch result.status {
            case .inspected: scanCursor = result.nextCursor; scanNotice = "Archive inspected. Selected bytes still require re-verification before retention."
            case .sourceUnavailable: scanCursor = result.nextCursor; scanNotice = "The last archive was unavailable. Continue to inspect the next archive."
            case .archiveUnavailable: scanNotice = "The archive directory is unavailable."
            case .complete: scanDone = true; scanNotice = "Archive scan complete."
            case .deferred: scanNotice = "Inspection was deferred. The scan cursor and your selections are preserved."
            }
            await loadSources(cohort: cohort, cursor: sourceCursor)
            await refreshAdmission()
        } catch { if !Task.isCancelled { scanError = error.localizedDescription } }
    }
    func restartScan() {
        guard !scanning else { return }
        scanCursor = nil; scanDone = false; scanNotice = nil; scanError = nil
    }
}
