import Foundation
import Observation

/// A maintenance session follows one owner's operation; it never queues or replays a hardware request.
@MainActor @Observable final class ArrangementMaintenanceWorkspace {
    let connection: PersonalBedConnection
    private(set) var status: ArrangementMaintenanceStatus?
    private(set) var cancellation: ArrangementCancellationPreview?
    private(set) var loaded = false
    private(set) var busy = false
    private(set) var entered = false
    private(set) var canActivate = false
    private(set) var error: String?
    private(set) var notice: String?
    var confirmations: Set<String> = []
    private let client: any ArrangementMaintenanceTransport
    private let reviews: any ArrangementReviewTransport
    private let permitted: @MainActor () -> Bool
    private let onEnter: @MainActor () -> Void
    private let onFinish: @MainActor () -> Void
    private let revoked: @MainActor () -> Void
    private let clock: @MainActor () -> Int64
    private var generation = 0
    private var invalidated = false
    private var operationId: UUID?

    init(connection: PersonalBedConnection, client: any ArrangementMaintenanceTransport, reviews: any ArrangementReviewTransport,
         permitted: @escaping @MainActor () -> Bool = { true }, entered: @escaping @MainActor () -> Void = {},
         finished: @escaping @MainActor () -> Void = {}, revoked: @escaping @MainActor () -> Void = {},
         now: @escaping @MainActor () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.connection = connection; self.client = client; self.reviews = reviews; self.permitted = permitted
        onEnter = entered; onFinish = finished; self.revoked = revoked; clock = now
    }
    var enabled: Bool { !invalidated && permitted() && connection.session.role == "owner" && connection.session.capabilities.arrangementMaintenance == true }
    var currentOperation: ArrangementMaintenanceStatus.Operation? { loaded ? status?.operation : nil }
    func canStart(_ review: ArrangementReview) -> Bool {
        enabled && loaded && !entered && canActivate && review.canActivate
            && review.state(at: clock()) == .approved && status?.allowsReview(review) == true
    }
    func confirmed(_ action: ArrangementMaintenanceRequest.Action) -> Bool {
        enabled && loaded && !busy && confirmations == action.confirmations
    }
    private func check(_ current: Int) throws {
        guard !invalidated, current == generation else { throw CancellationError() }
        guard permitted() else { throw HouseholdFailure.changedIdentity }
    }
    private func owner(_ current: Int) async throws -> HouseholdSession {
        let session = try await client.session(); try check(current)
        try ArrangementMaintenanceValidation.owner(session, anchoredTo: connection.session)
        return session
    }
    private func enter() {
        guard !entered else { return }
        entered = true; onEnter()
    }
    private func checkedStatus(_ current: Int) async throws -> (ArrangementMaintenanceStatus, HouseholdSession) {
        let before = try await owner(current)
        let value = try await client.status(operationId: operationId); try check(current)
        let after = try await owner(current)
        guard before.context == after.context else { throw HouseholdFailure.conflict }
        try value.validate(for: after, now: clock(), operationId: operationId?.uuidString.lowercased())
        if let operation = value.operation { operationId = UUID(uuidString: operation.operationId) }
        status = value; loaded = true; canActivate = after.capabilities.activateArrangement; error = nil
        if value.operation?.pending == true { enter() }
        try check(current)
        return (value, after)
    }
    private func fail(_ failure: Error, current: Int) {
        guard !invalidated, current == generation else { return }
        loaded = false; cancellation = nil; confirmations = []; canActivate = false
        if let failure = failure as? HouseholdFailure, [.changedIdentity, .authentication].contains(failure) {
            invalidate(); revoked(); return
        }
        error = "The result could not be verified. Check the saved transition; no action will be repeated."
    }
    func refresh() async {
        guard enabled, !busy else { return }
        let current = generation
        busy = true; cancellation = nil; confirmations = []; error = nil
        defer { if current == generation { busy = false } }
        do {
            _ = try await checkedStatus(current)
            notice = "Saved transition checked. No action was repeated."
        } catch { fail(error, current: current) }
    }
    private func operation(_ run: (Int, HouseholdSession, ArrangementMaintenanceStatus) async throws -> Void) async {
        guard enabled, !busy, loaded, let expected = status else { return }
        let current = generation
        busy = true; error = nil; notice = nil; confirmations = []
        defer { if current == generation { busy = false } }
        do {
            let (value, session) = try await checkedStatus(current)
            guard value.expectedSessionRevision == expected.expectedSessionRevision,
                  value.expectedAssignmentRevision == expected.expectedAssignmentRevision,
                  value.operation?.operationId == expected.operation?.operationId,
                  value.operation?.state == expected.operation?.state else { throw HouseholdFailure.conflict }
            try await run(current, session, value)
        } catch { fail(error, current: current) }
    }
    private func pending(_ status: ArrangementMaintenanceStatus, state: ArrangementMaintenanceStatus.Operation.State? = nil) throws -> ArrangementMaintenanceStatus.Operation {
        guard let operation = status.operation, operation.pending, operation.admission == .thisTransition,
              state == nil || state == operation.state else { throw HouseholdFailure.conflict }
        return operation
    }
    private func submit(_ request: ArrangementMaintenanceRequest, session: HouseholdSession, current: Int) async throws -> ArrangementMaintenanceResult {
        try check(current); enter(); try check(current)
        loaded = false; cancellation = nil
        let result = try await client.send(request, session: session); try check(current)
        return result
    }
    func activate(_ review: ArrangementReview) async {
        guard confirmed(.activate), !entered else { return }
        let checked = confirmations
        await operation { current, session, status in
            guard session.capabilities.activateArrangement, status.allowsReview(review), session.arrangement.mode == "solo-anywhere" else { throw HouseholdFailure.conflict }
            let index = try await reviews.latest(); try check(current)
            guard index.version == 1, let fresh = index.review else { throw HouseholdFailure.invalid }
            try fresh.validate(for: session)
            guard fresh.reviewId == review.reviewId, fresh.state(at: clock()) == .approved, fresh.canActivate,
                  status.allowsReview(fresh) else { throw HouseholdFailure.conflict }
            let after = try await owner(current)
            guard after.context == session.context else { throw HouseholdFailure.conflict }
            let request = try ArrangementMaintenanceRequest(action: .activate, session: after, referenceId: fresh.reviewId, confirmations: checked, now: clock())
            operationId = UUID(uuidString: request.requestId)
            guard case .activated = try await submit(request, session: after, current: current) else { throw HouseholdFailure.invalid }
            _ = try await checkedStatus(current)
            notice = "Side transition saved. Finish the attended restart and recovery before using the bed."
        }
    }
    func restart() async {
        guard confirmed(.restart) else { return }
        let checked = confirmations
        await operation { current, session, status in
            let pending = try pending(status)
            guard pending.restart == nil, pending.controllerRestarted == false else { throw HouseholdFailure.conflict }
            let request = try ArrangementMaintenanceRequest(action: .restart, session: session, referenceId: pending.operationId, confirmations: checked, now: clock())
            guard case .restarted(let receipt, _) = try await submit(request, session: session, current: current) else { throw HouseholdFailure.invalid }
            notice = receipt.state == .submitted
                ? "Restart requested. Reconnect and check its saved result; controls remain paused."
                : "The restart could not be confirmed. Check the saved result; it will not be requested again."
        }
    }
    func recover() async {
        guard confirmed(.recover) else { return }
        let checked = confirmations
        await operation { current, session, status in
            let pending = try pending(status, state: .committed)
            guard pending.controllerRestarted == true else { throw HouseholdFailure.conflict }
            let request = try ArrangementMaintenanceRequest(action: .recover, session: session, referenceId: pending.operationId, confirmations: checked, now: clock())
            guard case .recovered(let receipt, let services, _) = try await submit(request, session: session, current: current),
                  receipt.reviewId == pending.reviewId else { throw HouseholdFailure.invalid }
            _ = try await checkedStatus(current)
            notice = services == .resumed
                ? "Recovery was accepted and routine services resumed. Check each side before ordinary use."
                : "Recovery was recorded, but routine-service startup is unconfirmed. Check controller status before ordinary use."
        }
    }
    func previewCancellation() async {
        await operation { current, session, status in
            let pending = try pending(status, state: .held)
            guard pending.controllerRestarted == true, let identifier = UUID(uuidString: pending.operationId) else { throw HouseholdFailure.conflict }
            let preview = try await client.cancellationPreview(operationId: identifier); try check(current)
            let after = try await owner(current)
            guard after.context == session.context else { throw HouseholdFailure.conflict }
            try preview.validate(for: after, operationId: pending.operationId, now: clock())
            cancellation = preview
            notice = "Keeping the solo arrangement is ready to review. Saved routines may resume when you confirm."
        }
    }
    func cancel() async {
        guard confirmed(.cancel), let preview = cancellation else { return }
        let checked = confirmations
        await operation { current, session, status in
            let pending = try pending(status, state: .held)
            guard pending.controllerRestarted == true else { throw HouseholdFailure.conflict }
            try preview.validate(for: session, operationId: pending.operationId, now: clock(), maximumAge: 60_000)
            let request = try ArrangementMaintenanceRequest(action: .cancel, session: session, referenceId: pending.operationId,
                confirmations: checked, now: clock(), controlDigest: preview.controlDigest)
            guard case .cancelled(let receipt, let services, _) = try await submit(request, session: session, current: current),
                  receipt.reviewId == pending.reviewId, receipt.controlDigest == preview.controlDigest else { throw HouseholdFailure.invalid }
            _ = try await checkedStatus(current)
            notice = services == .resumed ? "Solo arrangement kept. Saved routine services resumed."
                : "Solo arrangement kept. Routine-service startup is unconfirmed; check controller status."
        }
    }
    func returnToControls() async {
        await operation { _, _, status in
            guard let operation = status.operation, [.completed, .cancelled].contains(operation.state), operation.admission == .open else { throw HouseholdFailure.conflict }
            onFinish()
        }
    }
    func background() {
        generation += 1; status = nil; cancellation = nil; loaded = false; busy = false; canActivate = false
        confirmations = []; notice = nil; error = nil
    }
    func invalidate() { background(); invalidated = true }
}
