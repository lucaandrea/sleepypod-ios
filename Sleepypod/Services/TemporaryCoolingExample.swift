#if DEBUG
import Foundation

/// Explicit UI-test fixture: it has no transport and cannot reach a Pod.
actor TemporaryCoolingExample: TemporaryCoolingClient, NativeControlClient {
    let unconfirmed: Bool
    let delayed: Bool
    private var lease: TemporaryCooling.Lease?
    private var receipts: [UUID: NativeControlReceipt] = [:]
    private var pendingReply: CheckedContinuation<Void, Error>?
    init(unconfirmed: Bool = false, delayed: Bool = false) { self.unconfirmed = unconfirmed; self.delayed = delayed }
    func available() {}
    func read(side: Side) -> TemporaryCooling {
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        if let lease, lease.expiresAt <= now { self.lease = nil }
        let scope = String(repeating: side == .left ? "a" : "b", count: 64)
        return .init(apiVersion: 1, side: side, generatedAt: now, state: lease == nil ? "ready" : "cooling",
            reason: "Practice · simulated cooling. No Pod is connected.", observedAt: now - 1000,
            proposal: lease == nil ? .init(scope: scope, fromTargetF: 70, targetF: 68, expiresAt: now + 1_200_000) : nil,
            lease: lease, physicalVerification: "unverified")
    }
    func submit(_ request: NativeControlRequest) async throws -> NativeControlReceipt {
        if delayed { try await waitForReply() }
        try request.validate()
        guard let side = request.action.side, let identifier = request.action.coolingId else { throw NativeControlFailure.invalid }
        if request.action.kind == "cooling.start", let scope = request.action.expectedScope, let expiry = request.action.expectedExpiresAt {
            lease = .init(version: 1, id: identifier, side: side, scope: scope, fromTargetF: 70, targetF: 68,
                          startedAt: request.issuedAt, expiresAt: expiry, sessionEndsAt: request.issuedAt + 28_800_000, phase: "active")
        } else if request.action.kind == "cooling.cancel" { if !unconfirmed { lease = nil } }
        else { throw NativeControlFailure.invalid }
        let result = NativeControlReceipt(version: 1, requestId: request.requestId, action: request.action,
            issuedAt: request.issuedAt, expiresAt: request.expiresAt, receivedAt: request.issuedAt, finishedAt: request.issuedAt,
            lastDispatchAt: request.issuedAt, state: "acknowledged", reason: nil, dispatchCount: 1, physicalVerification: "unverified", replayAllowed: false)
        receipts[request.requestId] = result
        if unconfirmed { throw NativeControlFailure.unavailable }
        return result
    }
    func read(_ request: NativeControlRequest) throws -> NativeControlReceipt {
        guard !unconfirmed, let result = receipts[request.requestId] else { throw NativeControlFailure.unavailable }
        return result
    }
    // The test advances the simulated response after observing pending UI, regardless of runner speed.
    func completeReply() { pendingReply?.resume(); pendingReply = nil }
    private func cancelReply() { pendingReply?.resume(throwing: CancellationError()); pendingReply = nil }
    private func waitForReply() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { pendingReply = continuation }
            }
        } onCancel: { Task { await self.cancelReply() } }
    }
}
#endif
