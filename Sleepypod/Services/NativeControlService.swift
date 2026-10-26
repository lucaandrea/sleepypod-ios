import Foundation

@MainActor final class NativeControlService {
    let ledger: NativeControlLedger
    private let client: @MainActor () throws -> any NativeControlClient
    private let owner: @MainActor () -> [String]
    private let live: @MainActor () -> Bool
    private let pause: @Sendable () async throws -> Void
    init(ledger: NativeControlLedger, client: @escaping @MainActor () throws -> any NativeControlClient,
         owner: @escaping @MainActor () -> [String] = { OwnerConnection.revision },
         live: @escaping @MainActor () -> Bool = { APIBackend.current == .sleepypodCore },
         pause: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(500)) }) {
        self.ledger = ledger; self.client = client; self.owner = owner; self.live = live; self.pause = pause
    }
    func history() throws -> [NativeControlAttempt] { Array(try ledger.read(scope: owner()).reversed()) }
    /// Persist first, POST once, then only read this immutable ID. An uncertain result is never replayed.
    func submit(_ action: NativeControlAction) async throws -> NativeControlAttempt {
        let scope = owner(); try check(scope)
        try action.validate()
        let transport = try client(); try await transport.available(); try check(scope)
        let previous = try ledger.read(scope: scope)
        guard action.isStopping || !previous.contains(where: { $0.needsReview && $0.request.action.family == action.family }) else { throw NativeControlFailure.unresolved }
        let request = try NativeControlRequest(action: action)
        try ledger.append(request, scope: scope)
        // No suspension between the durable claim and dispatch: another invocation sees the claim.
        var receipt: NativeControlReceipt?
        do { receipt = try await transport.submit(request); try receipt?.validate(for: request) }
        catch {
            receipt = nil
            if !Task.isCancelled, scope == owner(), live() { receipt = try? await transport.read(request) }
        }
        if let receipt { try ledger.save(receipt, scope: scope) }
        try check(scope)
        for _ in 0..<3 where receipt?.state == "executing" {
            try await pause(); try check(scope)
            do {
                let result = try await transport.read(request)
                try result.validate(for: request); try ledger.save(result, scope: scope); receipt = result
            } catch { break }
            try check(scope)
        }
        try check(scope)
        guard let attempt = try ledger.read(scope: scope).first(where: { $0.id == request.requestId }) else { throw NativeControlFailure.invalid }
        return attempt
    }
    func refresh(_ id: UUID) async throws -> NativeControlAttempt {
        let scope = owner(); try check(scope)
        guard let attempt = try ledger.read(scope: scope).first(where: { $0.id == id }) else { throw NativeControlFailure.invalid }
        let transport = try client()
        let result = try await transport.read(attempt.request)
        try result.validate(for: attempt.request); try ledger.save(result, scope: scope); try check(scope)
        guard let updated = try ledger.read(scope: scope).first(where: { $0.id == id }) else { throw NativeControlFailure.invalid }
        return updated
    }
    func review(_ id: UUID) throws { let scope = owner(); try check(scope); try ledger.review(id, scope: scope) }
    private func check(_ scope: [String]) throws {
        try Task.checkCancellation()
        guard scope == owner() else { throw NativeControlFailure.changedOwner }
        guard live() else { throw APIError.serverError(message: "System commands require your real sleepypod controller connection. Demo never sends a hardware command.") }
    }
}
