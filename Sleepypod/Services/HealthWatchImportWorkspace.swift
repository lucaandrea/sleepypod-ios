import Foundation
import Observation

@MainActor @Observable final class HealthWatchImportWorkspace {
    private(set) var snapshot: HealthWatchSnapshot?
    private(set) var reading = false
    private(set) var importing = false
    private(set) var complete = false
    private(set) var written = 0
    private(set) var processed = 0
    private(set) var error: String?
    var period: WatchImportPeriod = .month
    let side: Side
    let writer: (any HealthWatchReferenceWriting)?
    private var context: [String]?
    private var revision = 0
    var destination: String { writer?.destination ?? "No controller configured" }
    init(side: Side, writer: (any HealthWatchReferenceWriting)?) { self.side = side; self.writer = writer }

    func prepare(health: HealthSyncService) async {
        guard !reading, !importing else { return }
        reset(); let request = revision
        reading = true
        defer { if request == revision { reading = false } }
        let selectedContext = health.watchReferenceContext
        do {
            let value = try await health.watchReferenceSnapshot(side: side, days: period.rawValue)
            guard request == revision, !Task.isCancelled else { return }
            guard selectedContext == health.watchReferenceContext else { throw APIError.serverError(message: "Your connection or Health settings changed. Read the history again.") }
            snapshot = value; context = selectedContext
        } catch { if request == revision { self.error = error.localizedDescription } }
    }

    /// Recheck owner, consent and side before every batch; partial receipts remain visible on failure.
    func send(health: HealthSyncService) async {
        guard !importing, !reading, let snapshot, snapshot.count > 0, let writer, let context else { return }
        importing = true; complete = false; error = nil; written = 0; processed = 0
        defer { importing = false }
        do {
            for batch in HealthWatchBatch.batches(snapshot, side: side) {
                try Task.checkCancellation()
                guard context == health.watchReferenceContext else { throw APIError.serverError(message: "Your connection or Health settings changed. Read the history again.") }
                written += try await writer.write(batch)
                processed += batch.count
            }
            guard context == health.watchReferenceContext else { throw APIError.serverError(message: "The import finished after your connection or Health settings changed. Check the original destination.") }
            complete = true
        } catch {
            self.error = "Import incomplete. \(written) new records confirmed. " + error.localizedDescription
                + " Retrying skips identical records already stored; conflicting stages are never overwritten."
        }
    }
    func reset() {
        guard !importing else { return }
        revision += 1; snapshot = nil; context = nil; error = nil; complete = false; written = 0; processed = 0
    }
}
