import Foundation
import Observation

@MainActor @Observable final class ControllerUpdateWorkspace {
    let client: any ControllerUpdateServing
    private let journal: ControllerUpdateJournal
    private let now: () -> Date
    private(set) var snapshot: ControllerUpdateSnapshot?
    private(set) var review: ControllerUpdateReview?
    private(set) var attempt: ControllerUpdateAttempt?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var storageError = false
    var channel: ControllerUpdateChannel? { didSet { if channel != oldValue { review = nil } } }
    var canReview: Bool { !busy && !storageError && attempt == nil && channel != nil }
    var shouldObserve: Bool {
        guard let attempt, !storageError else { return false }
        return attempt.outcome == .observing || (attempt.internetWasBlocked && attempt.networkBlocked != true && (0..<180).contains(now().timeIntervalSince(attempt.startedAt)))
    }
    init(client: any ControllerUpdateServing, journal: ControllerUpdateJournal, now: @escaping () -> Date = Date.init) {
        self.client = client; self.journal = journal; self.now = now
        do { attempt = try journal.read(scope: client.scope) }
        catch { storageError = true; self.error = "The retained update request cannot be read. No update can be sent. \(error.localizedDescription)" }
    }
    func refresh() async {
        if attempt != nil { await observe(); return }
        guard !busy, !storageError else { return }
        busy = true; error = nil; review = nil
        defer { busy = false }
        do {
            let value = try await client.snapshot(); try Task.checkCancellation()
            snapshot = value
            if channel == nil { channel = ControllerUpdateChannel(rawValue: value.build.branch) }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func prepareReview() async {
        guard canReview, let selected = channel else { return }
        busy = true; error = nil; review = nil
        defer { busy = false }
        do {
            let value = try await client.snapshot(); try Task.checkCancellation()
            snapshot = value
            guard value.preservesInstalledRepository else {
                throw issue("This controller does not expose the installed-repository update contract. Update its updater through your installation tools before using native updates.")
            }
            guard value.build.knownIdentity else { throw issue("The installed build identity is unavailable. Check the controller before updating.") }
            guard channel == selected else { return }
            review = .init(build: value.build, channel: selected, internetBlocked: value.internetBlocked, readAt: now())
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    /// Retain before POST. Neither errors nor reopening ever repeat this non-idempotent endpoint.
    func start(_ reviewed: ControllerUpdateReview, allowTemporaryInternet: Bool) async {
        guard !busy, !storageError, attempt == nil, review == reviewed, channel == reviewed.channel else { return }
        guard !reviewed.internetBlocked || allowTemporaryInternet else { error = "Review temporary internet access before starting."; return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let age = now().timeIntervalSince(reviewed.readAt)
            guard (0...300).contains(age) else { review = nil; throw issue("The update review expired. Review the installed build again.") }
            let current = try await client.snapshot(); try Task.checkCancellation()
            guard current.preservesInstalledRepository, current.build == reviewed.build, current.internetBlocked == reviewed.internetBlocked else {
                snapshot = current; review = nil
                throw issue("The installed build or network state changed. Review again before updating.")
            }
            let pending = ControllerUpdateAttempt(id: UUID(), baseline: reviewed.build, channel: reviewed.channel,
                                                   internetWasBlocked: reviewed.internetBlocked, startedAt: now())
            try journal.replace(pending, expected: nil, scope: client.scope)
            attempt = pending; review = nil
        } catch { self.error = "No update was sent. \(error.localizedDescription)"; return }
        guard var pending = attempt else { return }
        do {
            let receipt = try await client.trigger(channel: pending.channel)
            guard receipt.triggered, receipt.branch == pending.channel.rawValue, !receipt.repository.isEmpty else {
                throw issue("The returned update receipt is incompatible.")
            }
            pending.receipt = receipt
        } catch { pending.dispatchError = "The update response was not confirmed. The app will only check status. \(error.localizedDescription)" }
        save(pending)
    }
    /// Polling records observations; even a connection gap does not prove that an updater succeeded.
    func observe() async {
        guard !busy, !storageError, var pending = attempt else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            guard try journal.read(scope: client.scope) == pending else { throw issue("The retained request changed in another view. Reopen Updates.") }
        } catch { storageError = true; self.error = error.localizedDescription; return }
        do {
            let build = try await client.version(); try Task.checkCancellation()
            pending.lastBuild = build; pending.lastReadError = nil; pending.lastVersionReadAt = now()
            pending.outcome = build.branch == pending.channel.rawValue && build.changed(from: pending.baseline) ? .changedBuild : .observing
        } catch {
            if Task.isCancelled { return }
            pending.sawConnectionGap = true; pending.lastReadError = error.localizedDescription
        }
        if pending.outcome != .changedBuild {
            let elapsed = now().timeIntervalSince(pending.startedAt)
            if elapsed >= 180 || elapsed < 0 { pending.outcome = .unconfirmed }
        }
        do {
            pending.networkBlocked = try await client.internetBlocked(); try Task.checkCancellation()
            pending.lastNetworkReadAt = now(); pending.restoreError = nil
        } catch {
            if Task.isCancelled { return }
            pending.networkBlocked = nil; pending.restoreError = "Network state could not be verified. \(error.localizedDescription)"
        }
        save(pending)
    }
    /// Restore is explicit and reads first, so a lost prior reply cannot cause an unnecessary repeat.
    func restoreLocalOnly() async {
        guard !busy, !storageError, var pending = attempt, pending.internetWasBlocked,
              pending.outcome != .observing else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            guard try journal.read(scope: client.scope) == pending else { throw issue("The retained request changed. Reopen Updates.") }
            let alreadyBlocked = try await client.internetBlocked()
            if !alreadyBlocked { _ = try await client.blockInternet() }
            pending.networkBlocked = try await client.internetBlocked()
            pending.lastNetworkReadAt = now()
            guard pending.networkBlocked == true else { throw issue("The controller still reports internet allowed.") }
            pending.restoreError = nil
        } catch {
            pending.networkBlocked = nil
            pending.restoreError = "Local-only restoration was not confirmed. Check the network state before another restore attempt. \(error.localizedDescription)"
        }
        save(pending)
    }
    func finishReview() {
        guard !busy, !storageError, let attempt else { return }
        do {
            try journal.replace(nil, expected: attempt, scope: client.scope)
            self.attempt = nil; review = nil; snapshot = nil; error = nil
        } catch { storageError = true; self.error = error.localizedDescription }
    }
    func discardUnreadableRecord() {
        guard !busy, storageError, attempt == nil else { return }
        do { try journal.discardUnreadable(scope: client.scope); storageError = false; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func save(_ pending: ControllerUpdateAttempt) {
        do { try journal.replace(pending, expected: attempt, scope: client.scope); attempt = pending }
        catch { storageError = true; self.error = "The request is retained, but its latest observation could not be saved. Reopen Updates. \(error.localizedDescription)" }
    }
    private func issue(_ message: String) -> APIError { .serverError(message: message) }
}
