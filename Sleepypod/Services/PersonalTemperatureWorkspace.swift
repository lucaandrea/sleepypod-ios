import Foundation
import Observation

@MainActor @Observable final class PersonalTemperatureWorkspace {
    let connection: PersonalBedConnection
    private(set) var bed: PersonalBed?
    private(set) var attempts: [PersonalControlAttempt] = []
    private(set) var error: String?
    private(set) var refreshing = false
    private(set) var readingsCurrent = false
    private(set) var requiresReview = false
    private(set) var draftTarget: Int?
    private(set) var clockDate = Date()
    var display: TemperatureDisplay = .degrees
    var holdMinutes = 30
    var unit: TemperatureFormat
    private let client: any PersonalBedTransport
    private let permitted: () -> Bool
    private let load: () throws -> [PersonalControlAttempt]
    private let save: (PersonalControlAttempt) throws -> Void
    private let recoveryPending: () -> Bool
    private let revoked: () -> Void
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private var generation = 0
    private var readGeneration = 0
    private var controlEpoch = 0
    private var receivedUptime: TimeInterval?
    private var inflight: [UUID: PersonalControlAction] = [:]
    private var receiptReads: [UUID: Int] = [:]
    private var storageReady = true

    init(connection: PersonalBedConnection, client: any PersonalBedTransport, unit: TemperatureFormat,
         permitted: @escaping () -> Bool, load: @escaping () throws -> [PersonalControlAttempt],
         save: @escaping (PersonalControlAttempt) throws -> Void,
         recoveryPending: @escaping () -> Bool = { false }, revoked: @escaping () -> Void = {},
         now: @escaping () -> Date = Date.init, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.connection = connection; self.client = client; self.unit = unit
        self.permitted = permitted; self.load = load; self.save = save; self.recoveryPending = recoveryPending; self.revoked = revoked; self.now = now; self.uptime = uptime
        clockDate = now()
        reloadAttempts()
    }
    var sending: Bool { !inflight.isEmpty }
    var hasUnresolved: Bool { attempts.contains(where: \.needsReview) || recoveryPending() }
    var available: Bool { permitted() && storageReady && bed?.availability == "ready" }
    var canAdjust: Bool { available && !requiresReview && !sending && !hasUnresolved && !(readingsCurrent && bed?.observation.priming == true) }
    var canStopPower: Bool { available && !inflight.values.contains { $0.kind == "power" && $0.powered == false } }
    var canStopVibration: Bool { available && !inflight.values.contains { $0.kind == "vibration.clear" } }
    var zones: [PersonalBed.Zone] { bed?.zones.map { readingsCurrent ? $0 : $0.withoutObservation } ?? [] }
    var target: Int? {
        if let draftTarget { return draftTarget }
        guard let first = bed?.zones.first?.requestedTargetF,
              bed?.zones.allSatisfy({ $0.requestedTargetF == first }) == true else { return nil }
        return Int(first.rounded())
    }
    var powered: Bool? {
        guard let first = zones.first?.reportedPowered, zones.allSatisfy({ $0.reportedPowered == first }) else { return nil }
        return first
    }
    func edit(fraction: Double) {
        guard canAdjust, fraction.isFinite else { return }
        draftTarget = display.target(at: fraction)
    }
    func step(_ delta: Int) async {
        guard canAdjust, let target else { return }
        await submit(.init(kind: "temperature", temperatureF: display.step(target, by: delta, unit: unit), holdMinutes: holdMinutes))
    }
    func commitDraft() async {
        guard canAdjust, let draftTarget else { return }
        await submit(.init(kind: "temperature", temperatureF: draftTarget, holdMinutes: holdMinutes))
    }
    func reviewScope() { if permitted(), bed?.availability == "ready" { requiresReview = false; draftTarget = nil } }
    func invalidate() {
        generation += 1; readGeneration += 1; bed = nil; draftTarget = nil
        readingsCurrent = false; refreshing = false; inflight = [:]; attempts = []; receivedUptime = nil
    }
    func tick() {
        clockDate = now()
        guard permitted(), let receivedUptime, let bed else { readingsCurrent = false; return }
        let age = uptime() - receivedUptime
        readingsCurrent = age >= 0 && age < 15 && bed.observation.isFresh(at: now())
        if !readingsCurrent { self.receivedUptime = nil }
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
    private func verifiedBed(_ operation: Int) async throws -> PersonalBed {
        let session = try await client.session()
        try check(operation); try session.validate()
        guard session.context == connection.session.context, session.person == connection.session.person,
              session.arrangement == connection.session.arrangement else { throw HouseholdFailure.changedIdentity }
        guard session.capabilities.personalControls else { throw HouseholdFailure.unavailable }
        let snapshot = try await client.bed()
        try check(operation); try snapshot.validate(for: session)
        return snapshot
    }
    private func apply(_ snapshot: PersonalBed) {
        if let previous = bed, previous.scope != snapshot.scope { requiresReview = true; draftTarget = nil }
        bed = snapshot; receivedUptime = uptime(); tick()
        if snapshot.availability != "ready" { draftTarget = nil }
    }
    func refresh() async {
        guard permitted(), !refreshing, !sending else { return }
        let operation = generation
        readGeneration += 1; let reading = readGeneration; refreshing = true; error = nil
        defer { if operation == generation, reading == readGeneration { refreshing = false } }
        do {
            let snapshot = try await verifiedBed(operation)
            guard reading == readGeneration else { return }
            apply(snapshot); reloadAttempts()
        } catch { if operation == generation, reading == readGeneration { fail(error) } }
    }
    /// Recheck session and configuration, then durably save the exact bytes before the sole POST.
    func submit(_ action: PersonalControlAction) async {
        guard action.isStopping ? (action.kind == "power" ? canStopPower : canStopVibration) : canAdjust,
              let reviewed = bed else { return }
        let operation = generation, reservation = UUID()
        // Stop supersedes ordinary actions still waiting for preflight; already-sent actions keep their receipts.
        if action.isStopping { controlEpoch += 1 }
        let epoch = controlEpoch
        inflight[reservation] = action; readGeneration += 1; refreshing = false; error = nil
        defer { if operation == generation { inflight[reservation] = nil } }
        do {
            try action.validate()
            let snapshot = try await verifiedBed(operation)
            guard action.isStopping || epoch == controlEpoch else { throw PersonalControlFailure.supersededByStop }
            guard snapshot.availability == "ready" else { apply(snapshot); throw HouseholdFailure.unavailable }
            guard snapshot.scope == reviewed.scope else { apply(snapshot); throw HouseholdFailure.conflict }
            let request = try PersonalControlRequest(scope: snapshot.scope, action: action, now: now())
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var attempt = PersonalControlAttempt(request: request, body: try encoder.encode(request), authorizedZones: snapshot.routing.zones(for: action))
            try attempt.validate(); try check(operation); try save(attempt); reloadAttempts()
            guard storageReady else { throw HouseholdFailure.storage }
            guard action.isStopping || epoch == controlEpoch else { throw PersonalControlFailure.supersededByStop }
            let receipt = try await client.submit(attempt.body)
            try check(operation); try receipt.validate(for: attempt)
            receiptReads[attempt.id, default: 0] += 1
            attempt.receipt = receipt; try save(attempt); reloadAttempts(); draftTarget = nil
        } catch { if operation == generation { fail(error, preserveBed: true) } }
    }
    /// Receipt lookups never resend the command, including after restart or a side move.
    func reconcile(_ id: UUID) async {
        guard permitted(), let original = attempts.first(where: { $0.id == id }) else { return }
        let operation = generation; error = nil
        receiptReads[id, default: 0] += 1
        let reading = receiptReads[id]
        do {
            let session = try await client.session()
            try check(operation); try session.validate()
            guard session.identity == connection.session.identity, session.context == connection.session.context else { throw HouseholdFailure.changedIdentity }
            let receipt = try await client.receipt(id)
            try check(operation); try receipt.validate(for: original)
            guard reading == receiptReads[id], var attempt = attempts.first(where: { $0.id == id }) else { return }
            attempt.receipt = receipt
            try save(attempt); reloadAttempts()
        } catch { if operation == generation, reading == receiptReads[id] { fail(error, preserveBed: true) } }
    }
    func canReview(_ attempt: PersonalControlAttempt) -> Bool {
        permitted() && attempt.needsReview && attempt.receipt?.state != "executing"
            && clockDate.timeIntervalSince1970 * 1_000 >= Double(attempt.request.expiresAt) && !sending
    }
    func markReviewed(_ id: UUID) {
        guard var attempt = attempts.first(where: { $0.id == id }), canReview(attempt) else { return }
        do { attempt.reviewedAt = now(); try save(attempt); reloadAttempts() }
        catch { storageReady = false; self.error = HouseholdFailure.storage.localizedDescription }
    }
    private func fail(_ failure: Error, preserveBed: Bool = false) {
        if let failure = failure as? HouseholdFailure,
           [.authentication, .forbidden, .changedIdentity].contains(failure) {
            invalidate()
            if failure == .authentication { revoked() }
        } else if !preserveBed { bed = nil; readingsCurrent = false; draftTarget = nil }
        if failure as? HouseholdFailure == .storage { storageReady = false }
        error = PersonalControlFailure.message(for: failure)
    }
}
