import Foundation
import Observation

/// Private, memory-only workflow. Interrupted writes require readback; no operation is retried automatically.
@MainActor @Observable final class ComfortExperimentWorkspace {
    struct Pending: Equatable {
        let id: String
        let action: String
        var planStopped = false
        var controlStopped = false
    }
    private struct Selection { let detail: ComfortExperimentDetail; let execution: ComfortExperimentExecution? }
    private enum Result {
        case library(ComfortExperimentLibrary)
        case review(ComfortExperimentReview, started: Date)
        case selected(Selection, notice: String?)
        case execution(ComfortExperimentExecution, started: Date, notice: String?)
        case refused(String)
    }
    private(set) var library: ComfortExperimentLibrary?
    private(set) var review: ComfortExperimentReview?
    private(set) var detail: ComfortExperimentDetail?
    private(set) var execution: ComfortExperimentExecution?
    private(set) var pending: Pending?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var executionAvailable = false
    private(set) var invalidated = false
    private(set) var secondsRemaining = 0
    private let client: any ComfortExperimentTransport
    private let permitted: @MainActor () -> Bool
    private let revoked: @MainActor () -> Void
    private let now: @MainActor () -> Date
    private var anchor: ComfortExperimentAccess?
    private var generation = 0
    private var checking = false
    private var reviewStarted: Date?
    private var reviewDeadline: Date?

    init(client: any ComfortExperimentTransport, permitted: @escaping @MainActor () -> Bool = { true },
         revoked: @escaping @MainActor () -> Void = {}, now: @escaping @MainActor () -> Date = { .now }) {
        self.client = client; self.permitted = permitted; self.revoked = revoked; self.now = now
    }
    var enabled: Bool { !invalidated && permitted() }
    var currentDate: Date { now() }
    var canChange: Bool { enabled && !busy && pending == nil }
    var canStop: Bool { canChange && detail != nil && (detail?.record.status == "planned" || execution?.state == "admitted") }
    var canConfirmPlan: Bool { canChange && review != nil && secondsRemaining > 0 }
    var canConfirmControl: Bool { canChange && execution?.review != nil && secondsRemaining > 0 }

    func suspend() {
        generation += 1; library = nil; detail = nil; execution = nil; discardReview(); busy = false; error = nil; notice = nil
    }
    func invalidate() { invalidated = true; suspend(); pending = nil; anchor = nil }
    func discardReview() { review = nil; execution?.review = nil; reviewStarted = nil; reviewDeadline = nil; secondsRemaining = 0 }
    func tick() {
        guard let started = reviewStarted, let deadline = reviewDeadline else { secondsRemaining = 0; return }
        guard now() >= started, now() < deadline else { discardReview(); notice = "The review expired. Review again before confirming."; return }
        secondsRemaining = Int(ceil(deadline.timeIntervalSince(now())))
    }
    private func current(_ operation: Int) throws {
        guard generation == operation, enabled, !Task.isCancelled else { throw HouseholdFailure.changedIdentity }
    }
    private func access(_ operation: Int) async throws -> ComfortExperimentAccess {
        let value = try await client.access(); try current(operation); try value.scope.validate()
        if let anchor, anchor != value { throw HouseholdFailure.changedIdentity }
        return value
    }
    private func decode<Value: ComfortExperimentEnvelope>(_ type: Value.Type, action: ComfortExperimentRequest,
                                                          access: ComfortExperimentAccess, operation: Int) async throws -> Value {
        let data = try await client.request(action); try current(operation)
        let value = try ComfortExperimentDecoding.decode(type, data: data)
        try value.validateEnvelope(scope: access.scope, now: ComfortExperimentContract.now(now()))
        return value
    }
    private func selection(_ id: String, access: ComfortExperimentAccess, operation: Int) async throws -> Selection {
        let detail = try await decode(ComfortExperimentDetail.self, action: .detail(id), access: access, operation: operation)
        try detail.validate(id: id)
        var execution: ComfortExperimentExecution?
        if access.execution {
            execution = try await decode(ComfortExperimentExecution.self, action: .execution(id), access: access, operation: operation)
            try execution?.validate(record: detail.record)
        }
        return .init(detail: detail, execution: execution)
    }
    private func control(_ action: ComfortExperimentRequest, record: ComfortExperimentRecord,
                         access: ComfortExperimentAccess, operation: Int) async throws -> ComfortExperimentExecution {
        guard access.execution else { throw HouseholdFailure.unavailable }
        let result = try await decode(ComfortExperimentExecution.self, action: action, access: access, operation: operation)
        try result.validate(record: record); return result
    }
    private func perform(_ work: (ComfortExperimentAccess, Int, Date) async throws -> Result) async {
        guard enabled, !busy else { return }
        generation += 1; let operation = generation, started = now(); busy = true; error = nil; notice = nil
        defer { if generation == operation { busy = false } }
        var verified = false
        do {
            let before = try await access(operation); anchor = before; verified = true
            let result = try await work(before, operation, started)
            let after = try await access(operation)
            guard before == after else { throw HouseholdFailure.changedIdentity }
            apply(result); executionAvailable = after.execution; pending = nil
        } catch {
            guard generation == operation else { return }
            var failure = error
            // Business errors may contain private routine context; verify access
            // again before presenting one after an awaited request.
            if failure is ComfortExperimentFailure {
                do { _ = try await access(operation) } catch { failure = error }
                guard generation == operation else { return }
            }
            if failure as? HouseholdFailure == .changedIdentity || failure as? HouseholdFailure == .authentication
                || failure as? HouseholdFailure == .forbidden || !permitted() {
                invalidate(); self.error = "Your connection or account changed. Reopen comparisons from your current account."
                if failure as? HouseholdFailure == .authentication { revoked() }
            } else {
                let waiting = verified ? pending : nil
                suspend(); pending = waiting
                if let waiting {
                    self.error = waiting.controlStopped ? "The plan and its control authorization are stopped. Refresh the saved result; nothing will be resent."
                        : waiting.planStopped ? "The plan is closed, but control cancellation is not yet confirmed. Check the saved result."
                        : "The result is uncertain. Check the saved result before making another change; nothing will be resent."
                } else { self.error = (failure as? ComfortExperimentFailure)?.localizedDescription ?? "The comparison could not be verified. Reopen it to check your connection and routines." }
            }
        }
    }
    private func apply(_ result: Result) {
        switch result {
        case .library(let value): library = value; detail = nil; execution = nil; discardReview()
        case .review(let value, let started):
            library = nil; detail = nil; execution = nil; review = value
            startDeadline(started, duration: value.expiresAt - value.generatedAt)
        case .selected(let value, let message):
            library = nil; discardReview(); detail = value.detail; execution = value.execution; execution?.review = nil; notice = message
        case .execution(let value, let started, let message):
            execution = value; review = nil; notice = message
            if let pendingReview = value.review { startDeadline(started, duration: pendingReview.expiresAt - value.generatedAt) }
            else { reviewStarted = nil; reviewDeadline = nil; secondsRemaining = 0 }
        case .refused(let message): execution?.review = nil; reviewStarted = nil; reviewDeadline = nil; secondsRemaining = 0; error = message
        }
    }
    private func startDeadline(_ started: Date, duration: Int64) {
        // Starting before the network round trip prevents slow replies from extending consent.
        reviewStarted = started; reviewDeadline = started.addingTimeInterval(Double(duration) / 1000); tick()
    }
    func open(older: Bool = false) async {
        if pending != nil { await reconcile(); return }
        let cursor = older ? library?.nextId : nil
        if older && cursor == nil { return }
        await perform { access, operation, _ in
            let value = try await self.decode(ComfortExperimentLibrary.self, action: .library(after: cursor), access: access, operation: operation)
            try value.validate(); return .library(value)
        }
    }
    func select(_ id: String) async {
        guard pending == nil else { return }
        await perform { access, operation, _ in .selected(try await self.selection(id, access: access, operation: operation), notice: nil) }
    }
    func preview(_ proposal: ComfortExperimentProposal) async {
        guard pending == nil else { return }
        await perform { access, operation, started in
            try proposal.validate()
            let value = try await self.decode(ComfortExperimentReview.self, action: .preview(proposal), access: access, operation: operation)
            try value.validate(proposal: proposal); return .review(value, started: started)
        }
    }
    func savePlan() async {
        tick(); guard canConfirmPlan, let review else { return }
        await perform { access, operation, _ in
            self.pending = .init(id: review.plan.id, action: "save")
            let result = try await self.decode(ComfortExperimentDetail.self, action: .save(reviewId: review.reviewId, hash: review.planHash), access: access, operation: operation)
            try result.validate(id: review.plan.id)
            try ComfortExperimentContract.require(result.record.plan == review.plan)
            return .selected(try await self.selection(review.plan.id, access: access, operation: operation), notice: "Comparison saved. Overnight control has not been activated.")
        }
    }
    func reviewControl() async {
        guard canChange, executionAvailable, let detail, detail.record.status == "planned", detail.contextCurrent, execution?.state != "admitted" else { return }
        await perform { access, operation, started in
            do {
                let value = try await self.control(.reviewControl(detail.record.plan.id), record: detail.record, access: access, operation: operation)
                try ComfortExperimentContract.require(value.review != nil)
                return .execution(value, started: started, notice: nil)
            } catch let failure as ComfortExperimentFailure { return .refused(failure.localizedDescription) }
        }
    }
    func confirmControl() async {
        tick(); guard canConfirmControl, let review = execution?.review, let detail else { return }
        await perform { access, operation, started in
            self.pending = .init(id: detail.record.plan.id, action: "authorize")
            let value = try await self.control(.confirmControl(id: detail.record.plan.id, reviewId: review.id, hash: review.planHash), record: detail.record, access: access, operation: operation)
            try ComfortExperimentContract.require(value.state == "admitted" && value.admission?.id == review.id && value.admission?.sides == review.sides)
            return .execution(value, started: started, notice: "Overnight comparison authorized for its scheduled nights. Wake warming stays separate.")
        }
    }
    func stop() async {
        guard canStop, let detail else { return }
        await perform { access, operation, _ in
            let id = detail.record.plan.id
            self.pending = .init(id: id, action: "stop")
            // Close first so a second device cannot authorize the plan between cancellation and closure.
            let closed = try await self.decode(ComfortExperimentDetail.self, action: .stop(id: id, revision: detail.record.revision), access: access, operation: operation)
            try closed.validate(id: id); try ComfortExperimentContract.require(closed.record.status == "stopped")
            self.pending?.planStopped = true
            let current = try await self.selection(id, access: access, operation: operation)
            if let admission = current.execution?.admission, current.execution?.state == "admitted" {
                let cancelled = try await self.control(.cancelControl(id: id, admissionId: admission.id), record: current.detail.record, access: access, operation: operation)
                try ComfortExperimentContract.require(cancelled.state == "revoked" && cancelled.admission?.id == admission.id)
                self.pending?.controlStopped = true
            }
            let saved = try await self.selection(id, access: access, operation: operation)
            try ComfortExperimentContract.require(saved.execution?.state != "admitted")
            return .selected(saved, notice: "Comparison stopped. Further experiment adjustments are disabled. Check the bed controls for the current target.")
        }
    }
    func saveFeedback(_ feedback: ComfortExperimentFeedback) async {
        guard canChange, let detail else { return }
        await perform { access, operation, _ in
            try feedback.validate(); self.pending = .init(id: detail.record.plan.id, action: "feedback")
            let saved = try await self.decode(ComfortExperimentDetail.self,
                action: .feedback(id: detail.record.plan.id, revision: detail.record.revision, value: feedback), access: access, operation: operation)
            try saved.validate(id: detail.record.plan.id)
            return .selected(try await self.selection(detail.record.plan.id, access: access, operation: operation), notice: "Morning feedback saved. Ratings alone do not confirm the temperature you received.")
        }
    }
    func recover(_ applicationId: String) async {
        guard canChange, let detail, let admission = execution?.admission,
              execution?.applications.contains(where: { $0.id == applicationId && $0.uncertain }) == true else { return }
        await perform { access, operation, started in
            self.pending = .init(id: detail.record.plan.id, action: "recover")
            let saved = try await self.control(.recover(id: detail.record.plan.id, admissionId: admission.id, applicationId: applicationId), record: detail.record, access: access, operation: operation)
            try ComfortExperimentContract.require(saved.state == "revoked" && saved.admission?.id == admission.id
                && saved.applications.first(where: { $0.id == applicationId })?.outcome == "resolved")
            return .execution(saved, started: started, notice: "Fresh firmware target checked and old authorization ended. No temperature command was replayed.")
        }
    }
    func reconcile() async {
        guard let pending else { return }
        await perform { access, operation, _ in
            .selected(try await self.selection(pending.id, access: access, operation: operation), notice: "Current saved record loaded. Check its status below; no write was repeated.")
        }
    }
    func checkAccess() async {
        guard enabled, !busy, !checking, anchor != nil, library != nil || review != nil || detail != nil else { return }
        let operation = generation; checking = true
        defer { checking = false }
        do {
            let before = try await access(operation)
            if let detail, before.execution, execution?.review == nil, pending == nil, review == nil {
                let result = try await selection(detail.record.plan.id, access: before, operation: operation)
                let after = try await access(operation)
                try ComfortExperimentContract.require(before == after)
                self.detail = result.detail; execution = result.execution; execution?.review = nil
            }
        } catch {
            guard generation == operation else { return }
            invalidate(); self.error = "Account access could not be verified. Reopen comparisons from your current account."
        }
    }
}
