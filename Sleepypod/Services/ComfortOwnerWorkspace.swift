import Foundation
import Observation

@MainActor @Observable final class ComfortOwnerWorkspace {
    private var client: (any ComfortOwnerClient)?
    private var side: Side = .left
    private var owner: [String] = []
    private var generation = 0
    private var reviewStarted: Date?
    private var reviewDeadline: Date?
    private let now: () -> Date
    private(set) var status: ComfortOwnerStatus?
    private(set) var review: ComfortOwnerReview?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var requiresReload = false
    private(set) var secondsRemaining = 0
    private(set) var demo = false
    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func configure(client: (any ComfortOwnerClient)?, side: Side, demo: Bool = false) {
        invalidate(); self.client = client; self.side = side; self.demo = demo; owner = OwnerConnection.revision
        error = nil; notice = nil; requiresReload = false
    }
    func invalidate() { generation += 1; status = nil; cancelReview(); busy = false; client = nil }
    func cancelReview() { review = nil; reviewStarted = nil; reviewDeadline = nil; secondsRemaining = 0 }
    private func current(_ operation: Int) -> Bool { generation == operation && owner == OwnerConnection.revision && !Task.isCancelled }
    var canConfirm: Bool { !demo && !busy && !requiresReload && error == nil && review != nil && secondsRemaining > 0 }

    func tick() {
        guard let started = reviewStarted, let deadline = reviewDeadline else { secondsRemaining = 0; return }
        let value = now()
        guard value >= started, value < deadline else { secondsRemaining = 0; reviewDeadline = nil; return }
        secondsRemaining = Int(ceil(deadline.timeIntervalSince(value)))
    }
    func load() async {
        guard !busy, owner == OwnerConnection.revision, !Task.isCancelled else { return }
        cancelReview()
        guard let client else { error = "Connect to a controller to review qualification."; return }
        let operation = generation; busy = true
        defer { if generation == operation { busy = false } }
        do {
            let result = try await client.status(side: side); try result.validate(side: side)
            guard current(operation) else { return }
            status = result; error = nil; requiresReload = false
        } catch { if current(operation) { status = nil; self.error = error.localizedDescription } }
    }

    /// Preparation captures server-owned evidence; it never submits a physical observation.
    func prepare(_ purpose: ComfortOwnerPurpose, kind: ComfortQualificationKind? = nil) async {
        guard !busy, !requiresReload, error == nil, let client, let status, owner == OwnerConnection.revision, !Task.isCancelled,
              status.identity != nil, purpose != .activation || status.canActivate,
              purpose != .qualification || !status.active && kind != nil,
              purpose != .resolution || status.application?.uncertain == true else { return }
        cancelReview(); notice = nil
        let operation = generation, started = now(); busy = true
        let input = ComfortOwnerPrepare(side: side, purpose: purpose, kind: purpose == .qualification ? kind : nil)
        defer { if generation == operation { busy = false } }
        do {
            let result = try await client.prepare(input); try result.validate(for: input)
            guard current(operation) else { return }
            guard result.snapshot.identity == status.identity else { throw ComfortOwnerValidation.invalid }
            // Subtract the full round trip so network latency never extends the server's review window.
            review = result; reviewStarted = started; reviewDeadline = started.addingTimeInterval((result.expiresAt - result.at) / 1000)
            tick()
        } catch { if current(operation) { self.error = error.localizedDescription; requiresReload = true } }
    }

    /// Never replay an uncertain confirmation. An explicit refresh reads the controller's outcome.
    func confirm(confirmed: Bool, note: String) async -> Bool {
        tick()
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canConfirm, confirmed, trimmed.utf16.count <= 2000, let review, let client,
              owner == OwnerConnection.revision, !Task.isCancelled else { return false }
        let operation = generation; busy = true; notice = nil; requiresReload = true
        cancelReview()
        defer { if generation == operation { busy = false } }
        do {
            let receipt = try await client.confirm(.init(side: side, id: review.id, confirmed: true, note: trimmed))
            guard current(operation) else { return false }
            guard receipt.saved else { throw ComfortOwnerValidation.invalid }
            notice = "Owner review saved. Physical effects are reported separately."
            let result = try await client.status(side: side); try result.validate(side: side)
            guard current(operation) else { return false }
            status = result; requiresReload = false; error = nil; return true
        } catch {
            if current(operation) { status = nil; self.error = error.localizedDescription + " Refresh evidence before taking another action. This confirmation will not be replayed." }
            return false
        }
    }

    func retest(_ record: ComfortQualification) async {
        guard !demo, !busy, !requiresReload, error == nil, let client, owner == OwnerConnection.revision, !Task.isCancelled,
              status?.qualifications.contains(where: { $0.id == record.id && $0.kind == record.kind && $0.outcome == "confirmed" }) == true else { return }
        let operation = generation; busy = true; notice = nil; requiresReload = true; cancelReview()
        defer { if generation == operation { busy = false } }
        do {
            let receipt = try await client.retest(.init(side: side, kind: record.kind, expectedId: record.id))
            guard current(operation) else { return }
            guard receipt.saved else { throw ComfortOwnerValidation.invalid }
            notice = "Retest requested. Any existing activation is revoked."
            let result = try await client.status(side: side); try result.validate(side: side)
            guard current(operation) else { return }
            status = result; error = nil; requiresReload = false
        } catch { if current(operation) { status = nil; self.error = error.localizedDescription + " Refresh before retrying." } }
    }
}
