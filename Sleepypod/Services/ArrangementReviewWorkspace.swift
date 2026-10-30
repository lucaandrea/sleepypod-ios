import Foundation
import Observation

/// Ephemeral review state never enters the Keychain ledger or the bed-control queue.
@MainActor @Observable final class ArrangementReviewWorkspace {
    let connection: PersonalBedConnection
    private(set) var review: ArrangementReview?
    private(set) var loaded = false
    private(set) var busy = false
    private(set) var needsReconciliation = false
    private(set) var error: String?
    private(set) var notice: String?
    var ownerSide: Side = .right { didSet { if ownerSide != oldValue { preserveOperatingWeek = false } } }
    var preserveOperatingWeek = false
    var confirmMySide = false
    var confirmMyRoutine = false
    var acknowledgeSeparateActivation = false
    private let client: any ArrangementReviewTransport
    private let permitted: @MainActor () -> Bool
    private let ready: @MainActor () -> Bool
    private let revoked: @MainActor () -> Void
    private let clock: @MainActor () -> Int64
    private var generation = 0
    private var invalidated = false
    private var uncertainReviewId: UUID?

    init(connection: PersonalBedConnection, client: any ArrangementReviewTransport,
         permitted: @escaping @MainActor () -> Bool = { true }, ready: @escaping @MainActor () -> Bool = { true },
         revoked: @escaping @MainActor () -> Void = {}, now: @escaping @MainActor () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.connection = connection; self.client = client; self.permitted = permitted; self.ready = ready
        self.revoked = revoked; clock = now
    }
    var enabled: Bool { !invalidated && permitted() && connection.session.capabilities.arrangementReview == true }
    var isInvalidated: Bool { invalidated }
    var currentState: ArrangementReview.State? { review?.state(at: clock()) }
    var mayPrepare: Bool {
        enabled && loaded && !busy && !needsReconciliation && ready() && connection.session.role == "owner"
            && connection.session.arrangement.mode == "solo-anywhere"
            && (review == nil || review?.state == .cancelled || review?.state == .expired)
    }
    var canPropose: Bool { mayPrepare && preserveOperatingWeek }
    var canApprove: Bool {
        enabled && loaded && !busy && !needsReconciliation && ready() && currentState == .awaitingApproval
            && review?.canApprove == true && review?.person.approved == false
            && confirmMySide && confirmMyRoutine && acknowledgeSeparateActivation
    }
    var canCancel: Bool {
        !invalidated && permitted() && loaded && !busy && !needsReconciliation && ready()
            && review != nil && review?.state != .cancelled && review?.state != .consumed
    }
    func discardReview() {
        generation += 1; review = nil; loaded = false; busy = false; error = nil; notice = nil
        resetConfirmations()
    }
    func invalidate() { invalidated = true; discardReview(); uncertainReviewId = nil; needsReconciliation = false }
    func suspend() { discardReview() }

    /// A fresh GET is required on entry, after a lost reply, and after returning to the foreground.
    func refresh() async {
        guard !invalidated, permitted(), !busy else { return }
        let operation = generation; busy = true; loaded = false; error = nil; notice = nil; resetConfirmations()
        defer { if operation == generation { busy = false } }
        do {
            let session = try await freshSession(operation)
            if let uncertainReviewId {
                let original = try await client.review(uncertainReviewId)
                try check(operation); try original.validate(for: session)
                guard UUID(uuidString: original.reviewId) == uncertainReviewId else { throw HouseholdFailure.invalid }
            }
            let latest = try await client.latest()
            try check(operation); try accept(latest, session: session)
            needsReconciliation = false; uncertainReviewId = nil
            notice = "Current side review checked. No bed change was requested."
        } catch { fail(error, operation: operation) }
    }
    func propose() async { guard canPropose else { return }; await mutate(.propose) }
    func approve() async { guard canApprove else { return }; await mutate(.approve) }
    func cancel() async { guard canCancel else { return }; await mutate(.cancel) }

    /// Preflight rechecks the exact displayed review; only one POST is ever sent for an action.
    private func mutate(_ action: ArrangementRequest.Action) async {
        let operation = generation, reviewed = review, proposedSide = ownerSide
        busy = true; error = nil; notice = nil
        defer { if operation == generation { busy = false } }
        do {
            let session = try await freshSession(operation)
            guard ready(), action == .cancel || session.capabilities.arrangementReview == true else { throw HouseholdFailure.unavailable }
            let latest = try await client.latest()
            try check(operation)
            guard latest.version == 1 else { throw HouseholdFailure.invalid }
            try latest.review?.validate(for: session)
            guard latest.review == reviewed else {
                try accept(latest, session: session); resetConfirmations()
                throw HouseholdFailure.conflict
            }
            if action == .approve {
                guard let reviewed, reviewed.state(at: clock()) == .awaitingApproval, reviewed.canApprove,
                      confirmMySide, confirmMyRoutine, acknowledgeSeparateActivation else { throw HouseholdFailure.conflict }
            }
            if action == .propose {
                guard proposedSide == ownerSide, preserveOperatingWeek else { throw HouseholdFailure.conflict }
            }
            let request = ArrangementRequest(action: action, session: session, reviewId: reviewed?.reviewId, ownerSide: proposedSide, now: clock())
            let body = try JSONEncoder().encode(request)
            _ = try ArrangementRequest.decodeExact(body, action: action, session: session)
            try check(operation); guard ready() else { throw HouseholdFailure.conflict }
            loaded = false; needsReconciliation = true
            uncertainReviewId = action == .propose ? nil : reviewed.flatMap { UUID(uuidString: $0.reviewId) }
            resetConfirmations()
            let result = try await client.send(action, body: body)
            try check(operation); try result.validate(for: session)
            guard result.reviewId == (action == .propose ? request.requestId : reviewed?.reviewId),
                  action != .propose || result.person.proposedSide == proposedSide,
                  action != .approve || result.person.approved,
                  action != .cancel || result.state == .cancelled else { throw HouseholdFailure.invalid }
            review = result; loaded = true; needsReconciliation = false; uncertainReviewId = nil
            switch action {
            case .propose: notice = "Review prepared. Each person must approve their own side and routine."
            case .approve: notice = "Your approval is saved. Switching the bed still needs a separate activation."
            case .cancel: notice = "Side review cancelled. The bed is unchanged."
            }
        } catch { fail(error, operation: operation) }
    }
    private func freshSession(_ operation: Int) async throws -> HouseholdSession {
        let value = try await client.session()
        try check(operation); try value.validate()
        guard value == connection.session else { throw HouseholdFailure.changedIdentity }
        return value
    }
    private func accept(_ index: ArrangementIndex, session: HouseholdSession) throws {
        guard index.version == 1 else { throw HouseholdFailure.invalid }
        try index.review?.validate(for: session)
        review = index.review; loaded = true
    }
    private func check(_ operation: Int) throws {
        guard !invalidated, permitted(), operation == generation, !Task.isCancelled else { throw HouseholdFailure.changedIdentity }
    }
    private func resetConfirmations() {
        preserveOperatingWeek = false; confirmMySide = false; confirmMyRoutine = false; acknowledgeSeparateActivation = false
    }
    private func fail(_ failure: Error, operation: Int) {
        guard operation == generation else { return }
        loaded = false; resetConfirmations()
        if failure as? HouseholdFailure == .authentication {
            invalidate(); revoked(); error = HouseholdFailure.authentication.localizedDescription
        } else if failure as? HouseholdFailure == .changedIdentity {
            invalidate(); error = HouseholdFailure.changedIdentity.localizedDescription
        } else if needsReconciliation || failure as? HouseholdFailure == .uncertain {
            error = "The review result is unconfirmed. Check the current review before another action. This request will not be resent."
        } else if failure as? HouseholdFailure == .unavailable {
            error = "Side review is unavailable on this controller. Refresh your personal account before continuing."
        } else {
            error = (failure as? HouseholdFailure ?? .invalid).localizedDescription
        }
    }
}
