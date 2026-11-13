import Foundation
import Observation

@MainActor protocol BedtimeRitualStoring {
    func load(scope: String) throws -> BedtimeRitualSavedState?
    func save(_ state: BedtimeRitualSavedState) throws
}

/// Durable, explicit handoffs. Restoring or returning to the app can never launch audio.
@MainActor @Observable final class BedtimeRitualSession {
    let scope: String
    private(set) var state: BedtimeRitualSavedState?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var invalidated = false
    private let storage: any BedtimeRitualStoring
    private let current: @MainActor () -> Bool
    private let foreground: @MainActor () -> Bool
    private let quiet: @MainActor () async throws -> BedtimeRitualQuiet
    private let open: @MainActor (URL) async -> Bool
    private let now: @MainActor () -> Date
    private let uptime: @MainActor () -> TimeInterval
    private var generation = 0
    private var attemptUptime: TimeInterval?

    init(scope: String, storage: any BedtimeRitualStoring, current: @escaping @MainActor () -> Bool,
         foreground: @escaping @MainActor () -> Bool, quiet: @escaping @MainActor () async throws -> BedtimeRitualQuiet,
         open: @escaping @MainActor (URL) async -> Bool, now: @escaping @MainActor () -> Date = Date.init,
         uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.scope = scope; self.storage = storage; self.current = current; self.foreground = foreground
        self.quiet = quiet; self.open = open; self.now = now; self.uptime = uptime
    }

    var available: Bool { !invalidated && current() }
    var needsReview: Bool { state?.attempt?.needsReview == true }

    func restore() {
        guard !busy else { return }
        do {
            try check()
            var saved = try storage.load(scope: scope) ?? .init(version: 1, scope: scope)
            try saved.validate(scope: scope)
            // A relaunched process has no trustworthy live callback context. Never replay it.
            if var attempt = saved.attempt, attempt.acceptsCallback {
                attempt.outcome = .unknown; attempt.outcomeAt = max(now(), attempt.createdAt); saved.attempt = attempt
                try storage.save(saved)
            }
            state = saved; attemptUptime = nil; error = nil
        } catch { state = nil; fail(error) }
    }

    func confirmSetup(_ plan: BedtimeRitualPlan) {
        do {
            try checkForeground()
            guard !busy, !needsReview, var saved = state else { throw BedtimeRitualFailure.pending }
            try plan.validate()
            saved.setup = .init(plan: plan, reviewedAt: now()); saved.attempt = nil
            try persist(saved)
        } catch { fail(error) }
    }

    /// Starting respects shared quiet. Pausing is an explicit recovery action and never starts media.
    func launch(_ action: BedtimeRitualAttempt.Action, confirmsCurrentAudio: Bool = false) async {
        guard !busy else { return }
        let operation = generation
        busy = true; error = nil
        defer { if operation == generation { busy = false } }
        do {
            try checkForeground()
            guard let saved = state, let setup = saved.setup else { throw BedtimeRitualFailure.setupRequired }
            try setup.validate(now: now())
            if action == .start {
                guard !needsReview else { throw BedtimeRitualFailure.pending }
                let readAt = uptime()
                let status: BedtimeRitualQuiet
                do { status = try await quiet() }
                catch {
                    if error as? BedtimeRitualFailure == .accountChanged { throw BedtimeRitualFailure.accountChanged }
                    throw BedtimeRitualFailure.quietUnavailable
                }
                try checkOperation(operation)
                let elapsed = uptime() - readAt
                guard elapsed >= 0, elapsed < 15 else { throw BedtimeRitualFailure.quietUnavailable }
                try status.validate(scope: scope, now: now())
            } else {
                guard confirmsCurrentAudio, let previous = saved.attempt, previous.action == .start,
                      previous.outcome != .notOpened, previous.createdAt <= now(),
                      now().timeIntervalSince(previous.createdAt) < 12 * 3600 else { throw BedtimeRitualFailure.pending }
            }
            try checkOperation(operation)
            guard state == saved else { throw BedtimeRitualFailure.pending }
            let issued = now()
            let attempt = BedtimeRitualAttempt(requestId: UUID(), nonce: UUID(), action: action, plan: setup.plan,
                createdAt: issued, expiresAt: issued.addingTimeInterval(BedtimeRitualClock.callbackLifetime), outcome: .opening)
            let url = try BedtimeRitualURL.launch(attempt)
            var updated = saved; updated.attempt = attempt
            try persist(updated) // Save before any external effect; a crash must leave a recovery record.
            attemptUptime = uptime()
            let opened = await open(url)
            guard operation == generation else { return }
            try check()
            guard var latest = state, latest.attempt?.requestId == attempt.requestId,
                  latest.attempt?.outcome == .opening else { return } // A callback can beat UIApplication's completion.
            latest.attempt?.outcome = opened ? .handedOff : .notOpened
            latest.attempt?.outcomeAt = opened ? nil : max(now(), issued)
            try persist(latest)
            expire()
        } catch { if operation == generation { fail(error) } }
    }

    @discardableResult func receive(_ url: URL) -> Bool {
        do {
            try check()
            guard var saved = state, var attempt = saved.attempt, attempt.acceptsCallback,
                  callbackFresh(attempt), let outcome = BedtimeRitualURL.outcome(url, attempt: attempt) else { return false }
            attempt.outcome = outcome; attempt.outcomeAt = now(); saved.attempt = attempt
            try persist(saved); return true
        } catch { fail(error); return false }
    }

    func expire() {
        do {
            try check()
            guard var saved = state, var attempt = saved.attempt, attempt.acceptsCallback, !callbackFresh(attempt) else { return }
            attempt.outcome = .unknown; attempt.outcomeAt = max(now(), attempt.createdAt); saved.attempt = attempt
            try persist(saved)
        } catch { fail(error) }
    }

    /// User observations are labeled separately from Shortcut-reported completion.
    func observe(_ observation: BedtimeRitualAttempt.Observation) {
        do {
            try checkForeground()
            guard var saved = state, var attempt = saved.attempt, attempt.createdAt <= now(),
                  now().timeIntervalSince(attempt.createdAt) < 12 * 3600,
                  attempt.action == .start || observation == .stopped else { throw BedtimeRitualFailure.expired }
            attempt.playback = .init(observation: observation, observedAt: now()); saved.attempt = attempt
            try persist(saved)
        } catch { fail(error) }
    }

    /// Dismissing uncertainty is an explicit user choice, not proof of playback or cancellation.
    func acknowledgeResult() {
        do {
            try checkForeground()
            guard !busy, var saved = state, var attempt = saved.attempt else { throw BedtimeRitualFailure.pending }
            if attempt.acceptsCallback { attempt.outcome = .unknown; attempt.outcomeAt = max(now(), attempt.createdAt) }
            attempt.acknowledgedAt = max(now(), attempt.createdAt); saved.attempt = attempt
            try persist(saved); attemptUptime = nil
        } catch { fail(error) }
    }

    func invalidate() { generation += 1; invalidated = true; state = nil; busy = false; error = nil; attemptUptime = nil }
    private func callbackFresh(_ attempt: BedtimeRitualAttempt) -> Bool {
        guard let attemptUptime else { return false }
        let elapsed = uptime() - attemptUptime
        return elapsed >= 0 && elapsed < BedtimeRitualClock.callbackLifetime && now() >= attempt.createdAt && now() < attempt.expiresAt
    }
    private func check() throws {
        guard available else { throw BedtimeRitualFailure.accountChanged }
        guard BedtimeRitualClock.scope(scope), BedtimeRitualClock.valid(now()), uptime().isFinite else { throw BedtimeRitualFailure.invalid }
    }
    private func checkForeground() throws { try check(); guard foreground() else { throw BedtimeRitualFailure.foregroundRequired } }
    private func checkOperation(_ operation: Int) throws {
        try checkForeground()
        guard generation == operation, !Task.isCancelled else { throw CancellationError() }
    }
    private func persist(_ value: BedtimeRitualSavedState) throws {
        try check(); try value.validate(scope: scope)
        do { try storage.save(value) } catch { state = nil; throw BedtimeRitualFailure.storage }
        state = value; error = nil
    }
    private func fail(_ failure: Error) {
        if failure as? BedtimeRitualFailure == .accountChanged { invalidate() }
        error = (failure as? BedtimeRitualFailure)?.errorDescription ?? BedtimeRitualFailure.storage.errorDescription
    }
}
