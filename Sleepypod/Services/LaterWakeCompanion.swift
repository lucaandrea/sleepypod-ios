import Foundation
import Observation

/// Coordinates an explicit optional phone backup after the Pod's reviewed save.
/// Each system owns its result; an uncertain step never causes replay or rollback.
@MainActor @Observable final class LaterWakeCompanion {
    struct Review {
        let packet: LaterWakePacket
        let phone: BackupAlarmExpectation?
        let owner: String?
    }
    struct Outcome {
        enum Phone { case unchanged, confirmed, unconfirmed }
        let plan: NextAlarmState
        let phone: Phone
        let phoneMessage: String?
    }
    private(set) var includePhone = false
    private(set) var review: Review?
    private(set) var outcome: Outcome?
    private(set) var error: String?
    private(set) var busy = false
    private let backup: BackupAlarmCoordinator
    private let currentOwner: @MainActor () -> String?
    private var generation = 0
    private var connection: [String] = []

    init(backup: BackupAlarmCoordinator = .shared,
         owner: @escaping @MainActor () -> String? = BackupAlarmCoordinator.ownerScope) {
        self.backup = backup; currentOwner = owner
    }
    func setPhone(_ value: Bool) {
        guard !busy else { return }
        includePhone = value; review = nil; error = nil
    }
    func clearReview() { guard !busy else { return }; review = nil; error = nil }
    func invalidate() {
        generation += 1; busy = false; review = nil; outcome = nil; error = nil; includePhone = false
    }
    func canApply(_ model: NextAlarmWorkspace) -> Bool {
        guard !busy, let review, model.canApplyLater, review.packet == model.laterDraft?.packet,
              connection == OwnerConnection.revision else { return false }
        return review.phone == nil || review.owner == currentOwner()
    }
    func preview(_ model: NextAlarmWorkspace) async {
        guard !busy, model.canPreviewLater else { return }
        generation += 1; let operation = generation; connection = OwnerConnection.revision
        busy = true; review = nil; outcome = nil; error = nil
        defer { if generation == operation { busy = false } }
        await model.previewLater()
        guard isCurrent(operation), let packet = model.laterDraft?.packet else { return }
        do {
            let owner = currentOwner()
            let phone = includePhone ? try backup.reviewLaterWake(plan: packet.preview.before,
                receivedAt: model.receivedAt, expectedOwner: owner) : nil
            review = .init(packet: packet, phone: phone, owner: owner)
        } catch { self.error = error.localizedDescription }
    }
    func apply(_ model: NextAlarmWorkspace) async {
        guard canApply(model), let review, !Task.isCancelled else { return }
        generation += 1; let operation = generation; busy = true; error = nil; outcome = nil
        defer { if generation == operation { busy = false } }
        do {
            if let phone = review.phone { try backup.verifyReviewed(phone, expectedOwner: review.owner) }
        } catch { self.review = nil; self.error = error.localizedDescription; return }
        let saved = await model.applyLater()
        guard isCurrent(operation) else { return }
        self.review = nil
        guard let saved else { return } // No phone mutation when the Pod's result is unknown.
        guard let phone = review.phone else {
            outcome = .init(plan: saved, phone: .unchanged, phoneMessage: nil)
            return
        }
        outcome = .init(plan: saved, phone: .unconfirmed, phoneMessage: "Checking the phone backup…")
        await backup.schedule(plan: saved, receivedAt: model.receivedAt, expectedOwner: review.owner, expectation: phone)
        guard isCurrent(operation) else { return }
        let confirmed = backup.systemState == "scheduled" && backup.record?.owner == review.owner
            && backup.record?.side == saved.side && backup.record?.at == saved.alarm.flatMap { NextAlarmState.instant($0.at) }
        outcome = .init(plan: saved, phone: confirmed ? .confirmed : .unconfirmed, phoneMessage: backup.message)
    }
    private func isCurrent(_ operation: Int) -> Bool {
        generation == operation && connection == OwnerConnection.revision && !Task.isCancelled
    }
}
