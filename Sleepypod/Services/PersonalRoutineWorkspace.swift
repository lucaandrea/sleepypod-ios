import Foundation
import Observation

@MainActor @Observable final class PersonalRoutineWorkspace {
    let connection: PersonalBedConnection
    private(set) var review: PersonalRoutineReview?
    private(set) var attempts: [PersonalRoutineAttempt] = []
    private(set) var error: String?
    private(set) var refreshing = false
    private(set) var publishing = false
    private(set) var checking: Set<UUID> = []
    var confirmReplaceLiveWeek = false
    var acknowledgeCurrentTargetEffect = false
    private let client: any PersonalRoutineTransport
    private let permitted: () -> Bool
    private let ready: () -> Bool
    private let savedDraft: () -> HouseholdRoutinesResponse?
    private let load: () throws -> [PersonalRoutineAttempt]
    private let save: (PersonalRoutineAttempt) throws -> Void
    private let recoveryPending: () -> Bool
    private let revoked: () -> Void
    private let now: () -> Date
    private var generation = 0
    private var readGeneration = 0
    private var stopEpoch = 0
    private var receiptReads: [UUID: Int] = [:]
    private var storageReady = true

    init(connection: PersonalBedConnection, client: any PersonalRoutineTransport,
         permitted: @escaping () -> Bool, ready: @escaping () -> Bool,
         savedDraft: @escaping () -> HouseholdRoutinesResponse?,
         load: @escaping () throws -> [PersonalRoutineAttempt], save: @escaping (PersonalRoutineAttempt) throws -> Void,
         recoveryPending: @escaping () -> Bool = { false }, revoked: @escaping () -> Void = {}, now: @escaping () -> Date = Date.init) {
        self.connection = connection; self.client = client; self.permitted = permitted; self.ready = ready
        self.savedDraft = savedDraft; self.load = load; self.save = save; self.recoveryPending = recoveryPending; self.revoked = revoked; self.now = now
        reloadAttempts()
    }
    var enabled: Bool { permitted() && connection.session.capabilities.personalRoutinePublication == true }
    var hasUnresolved: Bool { attempts.contains(where: \.unresolved) || recoveryPending() }
    var canPublish: Bool {
        enabled && ready() && storageReady && !refreshing && !publishing && !hasUnresolved
            && confirmReplaceLiveWeek && acknowledgeCurrentTargetEffect && review?.canPublish == true && draftMatchesReview
    }
    private var draftMatchesReview: Bool {
        guard let review, let saved = savedDraft() else { return false }
        return saved.revision == review.draftRevision && saved.sleeperId == connection.session.selfSleeperId
            && PersonalRoutineWeek.normalized(saved.routines) == PersonalRoutineWeek.normalized(review.draftWeek)
    }
    func discardReview() {
        readGeneration += 1; review = nil; refreshing = false
        confirmReplaceLiveWeek = false; acknowledgeCurrentTargetEffect = false
    }
    func invalidate() {
        generation += 1; discardReview(); attempts = []; publishing = false; checking = []
    }
    func stopUnsentPublication() {
        stopEpoch += 1; confirmReplaceLiveWeek = false; acknowledgeCurrentTargetEffect = false
    }
    private func check(_ operation: Int) throws {
        guard permitted(), operation == generation, !Task.isCancelled else { throw HouseholdFailure.changedIdentity }
    }
    private func reloadAttempts() {
        do {
            let values = try load()
            try values.forEach {
                try $0.validate()
                guard $0.request.scope.belongs(to: connection.session) else { throw HouseholdFailure.changedIdentity }
            }
            guard Set(values.map(\.id)).count == values.count else { throw HouseholdFailure.invalid }
            attempts = values; storageReady = true
        } catch { storageReady = false; self.error = HouseholdFailure.storage.localizedDescription }
    }
    private func verifiedSession(_ operation: Int) async throws -> HouseholdSession {
        let session = try await client.session()
        try check(operation); try session.validate()
        guard session.context == connection.session.context, session.person == connection.session.person,
              session.arrangement == connection.session.arrangement else { throw HouseholdFailure.changedIdentity }
        return session
    }
    private func verifiedReview(_ operation: Int) async throws -> PersonalRoutineReview {
        let session = try await verifiedSession(operation)
        guard session.capabilities.personalRoutinePublication == true else { throw HouseholdFailure.unavailable }
        let snapshot = try await client.review()
        try check(operation); try snapshot.validate(for: session)
        return snapshot
    }
    private func apply(_ snapshot: PersonalRoutineReview) {
        review = snapshot; confirmReplaceLiveWeek = false; acknowledgeCurrentTargetEffect = false
    }
    func refresh() async {
        guard enabled, !refreshing, !publishing else { return }
        let operation = generation
        readGeneration += 1; let reading = readGeneration; refreshing = true; error = nil
        confirmReplaceLiveWeek = false; acknowledgeCurrentTargetEffect = false
        defer { if operation == generation, reading == readGeneration { refreshing = false } }
        do {
            let snapshot = try await verifiedReview(operation)
            guard reading == readGeneration else { return }
            apply(snapshot); reloadAttempts()
        } catch { if operation == generation, reading == readGeneration { review = nil; fail(error) } }
    }
    /// Revalidate the entire reviewed week, persist the exact request, then POST once.
    func publish() async {
        guard canPublish, let reviewed = review else { return }
        let operation = generation, epoch = stopEpoch
        publishing = true; readGeneration += 1; refreshing = false; error = nil
        defer { if operation == generation { publishing = false } }
        do {
            let current = try await verifiedReview(operation)
            guard epoch == stopEpoch else { throw PersonalRoutineFailure.supersededByStop }
            guard current == reviewed else { apply(current); throw HouseholdFailure.conflict }
            guard ready(), draftMatchesReview, !hasUnresolved else { throw HouseholdFailure.conflict }
            let request = try PersonalRoutineRequest(review: current, now: now())
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var attempt = PersonalRoutineAttempt(request: request, body: try encoder.encode(request), review: current)
            try attempt.validate(); try check(operation); try save(attempt); reloadAttempts()
            guard storageReady else { throw HouseholdFailure.storage }
            guard epoch == stopEpoch else { throw PersonalRoutineFailure.supersededByStop }
            discardReview()
            // Even an HTTP rejection can follow a durable save; every sent attempt stays recoverable.
            let receipt = try await client.publish(attempt.body)
            try check(operation); try receipt.validate(for: attempt)
            receiptReads[attempt.id, default: 0] += 1
            attempt.receipt = receipt; try save(attempt); reloadAttempts()
        } catch {
            if operation == generation {
                confirmReplaceLiveWeek = false; acknowledgeCurrentTargetEffect = false
                if error as? HouseholdFailure == .unavailable { review = nil }
                fail(error)
            }
        }
    }
    /// Receipt reads are valid for the same account after a side move, never as a replay.
    func reconcile(_ id: UUID) async {
        guard permitted(), !checking.contains(id), let original = attempts.first(where: { $0.id == id }) else { return }
        let operation = generation; error = nil; checking.insert(id)
        receiptReads[id, default: 0] += 1; let reading = receiptReads[id]
        defer { if operation == generation { checking.remove(id) } }
        do {
            _ = try await verifiedSession(operation)
            let receipt = try await client.publication(id)
            try check(operation); try receipt.validate(for: original)
            guard reading == receiptReads[id], var attempt = attempts.first(where: { $0.id == id }) else { return }
            if let previous = attempt.receipt, !receipt.mayReplace(previous) { return }
            attempt.receipt = receipt; try save(attempt); reloadAttempts()
        } catch { if operation == generation, reading == receiptReads[id] { fail(error) } }
    }
    private func fail(_ failure: Error) {
        if let failure = failure as? HouseholdFailure, [.authentication, .forbidden, .changedIdentity].contains(failure) {
            invalidate()
            if failure == .authentication { revoked() }
        }
        if failure as? HouseholdFailure == .storage { storageReady = false }
        error = PersonalRoutineFailure.message(for: failure)
    }
}
