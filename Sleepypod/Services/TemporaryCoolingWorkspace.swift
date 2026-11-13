import Foundation
import FreeSleepKit
import Observation

/// The Pod owns expiry. The app previews, submits once and reads the retained receipt.
@MainActor @Observable final class TemporaryCoolingWorkspace {
    enum Operation: Equatable {
        case refreshing, starting(TemporaryCooling.Proposal), cancelling, checking
        var title: String {
            switch self {
            case .refreshing: "Refreshing cooling state…"
            case .starting: "Sending cooling request…"
            case .cancelling: "Requesting cancellation…"
            case .checking: "Checking the existing receipt…"
            }
        }
    }
    private var activeOperation: Operation?
    var operation: Operation? { owner != nil && owner == currentOwner() ? activeOperation : nil }
    private var value: TemporaryCooling?
    private var owner: [String]?
    private var side: Side = .left
    private var generation = 0
    private var client: (any TemporaryCoolingClient)?
    private var controls: NativeControlService?
    private let currentOwner: () -> [String]?
    private let now: () -> Date
    private(set) var busy = false
    private(set) var notice: String?
    private(set) var attempt: NativeControlAttempt?
    var report: TemporaryCooling? { owner != nil && owner == currentOwner() ? value : nil }

    init(currentOwner: @escaping () -> [String]? = { PersonalWorkspaceBoundary.isActive ? nil : OwnerConnection.revision }, now: @escaping () -> Date = { .now }) {
        self.currentOwner = currentOwner; self.now = now
    }
    func configure(side: Side, client: (any TemporaryCoolingClient)?, controls: NativeControlService?) {
        invalidate(); self.side = side; self.client = client; self.controls = controls; owner = currentOwner()
    }
    func invalidate() { generation += 1; owner = nil; value = nil; attempt = nil; busy = false; notice = nil; activeOperation = nil }
    private func current(_ operation: Int, _ identity: [String]) -> Bool {
        generation == operation && owner == identity && identity == currentOwner() && !Task.isCancelled
    }
    func refresh() async {
        guard !busy, let owner, owner == currentOwner(), !Task.isCancelled else { return }
        busy = true; activeOperation = .refreshing; let operation = generation
        defer { if current(operation, owner) { busy = false; activeOperation = nil } }
        await read(operation: operation, identity: owner)
    }
    private func read(operation: Int, identity: [String]) async {
        guard current(operation, identity) else { return }
        do {
            guard let client else { throw NativeControlFailure.unavailable }
            let result = try await client.read(side: side)
            try result.validate(for: side)
            guard current(operation, identity) else { return }
            value = result
        } catch {
            guard current(operation, identity) else { return }
            value = nil
            notice = "Temporary cooling is unavailable. Reconnect to an updated Pod and check again."
        }
    }
    func start(_ preview: TemporaryCooling.Proposal) async {
        guard report?.matches(preview, at: now()) == true else { notice = "The proposal changed or expired. Refresh and review it again."; return }
        let action = NativeControlAction(kind: "cooling.start", side: side, coolingId: UUID().uuidString.lowercased(),
            expectedScope: preview.scope, expectedTargetF: preview.fromTargetF, expectedExpiresAt: preview.expiresAt)
        await send(action, preview: preview)
    }
    func cancel() async {
        guard let report, report.current(at: now()), let lease = report.lease else { return }
        await send(.init(kind: "cooling.cancel", side: side, coolingId: lease.id))
    }
    private func send(_ action: NativeControlAction, preview: TemporaryCooling.Proposal? = nil) async {
        guard !busy, let owner, owner == currentOwner(), let controls else { return }
        let operation = generation
        busy = true; notice = nil; activeOperation = preview.map(Operation.starting) ?? .cancelling
        defer { if current(operation, owner) { busy = false; activeOperation = nil } }
        do {
            let result = try await controls.submit(action) { [self] in
                guard current(operation, owner), action.side == side,
                      preview.map({ report?.matches($0, at: now()) == true }) ?? true else { throw NativeControlFailure.changedOwner }
            }
            guard current(operation, owner) else { return }
            attempt = result
            notice = result.receipt?.message ?? "The response was lost. Check the existing request or Command history; it will not be sent again."
        } catch {
            guard current(operation, owner) else { return }
            notice = error.localizedDescription
        }
        await read(operation: operation, identity: owner)
    }
    func checkRequest() async {
        guard !busy, let owner, owner == currentOwner(), let controls, let attempt else { return }
        let operation = generation
        busy = true; activeOperation = .checking
        defer { if current(operation, owner) { busy = false; activeOperation = nil } }
        do {
            let result = try await controls.refresh(attempt.id)
            guard current(operation, owner) else { return }
            self.attempt = result; notice = result.receipt?.message
        } catch {
            guard current(operation, owner) else { return }
            notice = "The receipt is unavailable. Open Command history and check the current Pod state before another action."
        }
        await read(operation: operation, identity: owner)
    }
}
