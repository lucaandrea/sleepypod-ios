import Foundation

struct PersonalRoutineChange: Codable, Equatable, Sendable {
    let dayOfWeek: DayOfWeek
    let operation: String
    static func between(_ before: [HouseholdRoutine], _ after: [HouseholdRoutine]) -> [Self] {
        DayOfWeek.allCases.compactMap { day in
            let old = before.first { $0.dayOfWeek == day }?.draft.normalized
            let new = after.first { $0.dayOfWeek == day }?.draft.normalized
            guard old != new else { return nil }
            return .init(dayOfWeek: day, operation: old == nil ? "create" : new == nil ? "remove" : "replace")
        }
    }
    static func validate(_ changes: [Self]) throws {
        guard changes.count <= 7, Set(changes.map(\.dayOfWeek)).count == changes.count,
              changes.allSatisfy({ ["create", "replace", "remove"].contains($0.operation) }) else { throw HouseholdFailure.invalid }
    }
}

enum PersonalRoutineWeek {
    static func drafts(_ snapshots: [BedtimeRoutineSnapshot]) -> [HouseholdRoutine] {
        snapshots.map { .init(dayOfWeek: $0.dayOfWeek, draft: $0.draft) }
    }
    static func normalized(_ week: [HouseholdRoutine]) -> [HouseholdRoutine] {
        DayOfWeek.allCases.compactMap { day in week.first { $0.dayOfWeek == day }.map { .init(dayOfWeek: day, draft: $0.draft.normalized) } }
    }
    static func validate(_ snapshots: [BedtimeRoutineSnapshot]) throws {
        guard snapshots.allSatisfy({ BedtimeRoutineTime.validRevision($0.revision) }) else { throw HouseholdFailure.invalid }
        try HouseholdRoutine.validate(drafts(snapshots))
    }
    static func duration(_ seconds: Int) -> String {
        let minutes = seconds / 60, remainder = seconds % 60
        return remainder == 0 ? "\(minutes) min" : "\(minutes) min \(remainder) sec"
    }
}

struct PersonalRoutineReview: Codable, Equatable, Sendable {
    let version: Int
    let scope: PersonalControlScope
    let sourceSide: Side
    let temperatureZones: [Side]
    let timeZone: String
    let draftRevision: Int
    let liveRevision: String
    let reviewRevision: String
    let liveWeek: [BedtimeRoutineSnapshot]
    let draftWeek: [HouseholdRoutine]
    let changes: [PersonalRoutineChange]
    let canPublish: Bool
    let reason: String
    let effect: String
    var explanation: String {
        switch reason {
        case "ready": "Review the entire week, including nights that will be removed."
        case "unchanged": "Your saved draft matches the current operating week."
        case "draft_not_prepared": "This new account has no prepared draft. Explicitly copy the current week, edit it and save your draft before publication."
        case "calendar_migration_required": "The existing calendar must be migrated before publishing a complete routine."
        default: "Routine publication is not enabled on this controller. Your drafts remain separate."
        }
    }
    func validate() throws {
        try scope.validate(); try PersonalRoutineWeek.validate(liveWeek); try HouseholdRoutine.validate(draftWeek)
        try PersonalRoutineChange.validate(changes)
        guard version == 1, HouseholdValidation.revision(draftRevision),
              BedtimeRoutineTime.validRevision(liveRevision), BedtimeRoutineTime.validRevision(reviewRevision),
              !timeZone.isEmpty, timeZone.utf16.count <= 100, TimeZone(identifier: timeZone) != nil,
              !temperatureZones.isEmpty, temperatureZones.count <= 2, Set(temperatureZones).count == temperatureZones.count,
              temperatureZones.contains(sourceSide), effect == "saved_routines_can_affect_the_current_target",
              ["ready", "unchanged", "draft_not_prepared", "calendar_migration_required", "publication_disabled"].contains(reason),
              canPublish == (reason == "ready"), !canPublish || (draftRevision > 1 && !changes.isEmpty),
              reason != "draft_not_prepared" || draftRevision == 1, reason != "unchanged" || changes.isEmpty,
              Set(changes.map { "\($0.dayOfWeek.rawValue):\($0.operation)" }) == Set(PersonalRoutineChange.between(PersonalRoutineWeek.drafts(liveWeek), draftWeek).map { "\($0.dayOfWeek.rawValue):\($0.operation)" }) else {
            throw HouseholdFailure.invalid
        }
    }
    func validate(for session: HouseholdSession) throws {
        try validate(); try session.validate()
        guard scope.matches(session), Set(temperatureZones) == Set(session.person.zones) else { throw HouseholdFailure.changedIdentity }
    }
}

struct PersonalRoutineRequest: Codable, Equatable, Sendable {
    let version: Int
    let requestId: UUID
    let scope: PersonalControlScope
    let issuedAt: Int64
    let expiresAt: Int64
    let reviewRevision: String
    let confirmReplaceLiveWeek: Bool
    let acknowledgeCurrentTargetEffect: Bool
    init(review: PersonalRoutineReview, now: Date, requestId: UUID = UUID()) throws {
        try review.validate()
        let instant = now.timeIntervalSince1970 * 1_000
        guard review.canPublish, instant.isFinite, instant > 0, instant < 8_640_000_000_000_000 - 60_000 else { throw HouseholdFailure.invalid }
        version = 1; self.requestId = requestId; scope = review.scope; reviewRevision = review.reviewRevision
        issuedAt = Int64(instant); expiresAt = issuedAt + 30_000
        confirmReplaceLiveWeek = true; acknowledgeCurrentTargetEffect = true
    }
    enum CodingKeys: String, CodingKey { case version, requestId, scope, issuedAt, expiresAt, reviewRevision, confirmReplaceLiveWeek, acknowledgeCurrentTargetEffect }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version); try values.encode(requestId.uuidString.lowercased(), forKey: .requestId)
        try values.encode(scope, forKey: .scope); try values.encode(issuedAt, forKey: .issuedAt); try values.encode(expiresAt, forKey: .expiresAt)
        try values.encode(reviewRevision, forKey: .reviewRevision); try values.encode(confirmReplaceLiveWeek, forKey: .confirmReplaceLiveWeek)
        try values.encode(acknowledgeCurrentTargetEffect, forKey: .acknowledgeCurrentTargetEffect)
    }
    func validate() throws {
        try scope.validate()
        guard version == 1, PersonalControlRequest.validInstant(issuedAt), PersonalControlRequest.validInstant(expiresAt),
              expiresAt > issuedAt, expiresAt - issuedAt <= 60_000, BedtimeRoutineTime.validRevision(reviewRevision),
              confirmReplaceLiveWeek, acknowledgeCurrentTargetEffect else { throw HouseholdFailure.invalid }
    }
    static func decodeExact(_ body: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: body)
        let fields = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        guard Set(fields?.keys.map { $0 } ?? []) == Set(["version", "requestId", "scope", "issuedAt", "expiresAt", "reviewRevision", "confirmReplaceLiveWeek", "acknowledgeCurrentTargetEffect"]) else { throw HouseholdFailure.invalid }
        try value.validate(); return value
    }
}

struct PersonalRoutineReceipt: Codable, Equatable, Sendable {
    let version: Int
    let requestId: UUID
    let scope: PersonalControlScope
    let sourceSide: Side
    let publishedAt: Int64
    let draftRevision: Int
    let reviewRevision: String
    let state: String
    var scheduler: String
    let publishedWeek: [BedtimeRoutineSnapshot]
    let changes: [PersonalRoutineChange]
    let physicalVerification: String
    let replayAllowed: Bool
    var unresolved: Bool { scheduler != "refreshed" }
    var message: String {
        switch scheduler {
        case "refreshed": "Week saved. Scheduler refreshed. Heating and vibration are not physically verified."
        case "pending": "Week saved. Scheduler refresh is pending. Check this receipt; do not publish again."
        default: "Week saved. Scheduler refresh is unconfirmed. Check this receipt and the current week. Controller recovery is required; publishing again is not recovery."
        }
    }
    func validate() throws {
        try scope.validate(); try PersonalRoutineWeek.validate(publishedWeek); try PersonalRoutineChange.validate(changes)
        guard version == 1, PersonalControlRequest.validInstant(publishedAt), HouseholdValidation.revision(draftRevision),
              BedtimeRoutineTime.validRevision(reviewRevision), state == "saved", ["pending", "refreshed", "unconfirmed"].contains(scheduler),
              !changes.isEmpty, physicalVerification == "unverified", !replayAllowed else { throw HouseholdFailure.invalid }
    }
    func validate(for attempt: PersonalRoutineAttempt) throws {
        try validate()
        guard requestId == attempt.id, scope == attempt.request.scope, reviewRevision == attempt.request.reviewRevision,
              sourceSide == attempt.review.sourceSide, draftRevision == attempt.review.draftRevision,
              publishedAt >= attempt.request.issuedAt, publishedAt <= attempt.request.expiresAt,
              PersonalRoutineWeek.normalized(PersonalRoutineWeek.drafts(publishedWeek)) == PersonalRoutineWeek.normalized(attempt.review.draftWeek),
              Set(changes.map { "\($0.dayOfWeek.rawValue):\($0.operation)" }) == Set(attempt.review.changes.map { "\($0.dayOfWeek.rawValue):\($0.operation)" }) else { throw HouseholdFailure.invalid }
    }
    /// Receipt contents are immutable; a late pending response cannot undo a confirmed refresh.
    func mayReplace(_ previous: Self) -> Bool {
        var comparison = self; comparison.scheduler = previous.scheduler
        return comparison == previous && (previous.scheduler != "refreshed" || scheduler == "refreshed")
            && (previous.scheduler != "unconfirmed" || scheduler != "pending")
    }
}

struct PersonalRoutineAttempt: Codable, Equatable, Identifiable, Sendable {
    let request: PersonalRoutineRequest
    let body: Data
    let review: PersonalRoutineReview
    var receipt: PersonalRoutineReceipt?
    var id: UUID { request.requestId }
    var unresolved: Bool { receipt?.unresolved ?? true }
    func validate() throws {
        try request.validate(); try review.validate()
        guard review.canPublish, request.scope == review.scope, request.reviewRevision == review.reviewRevision,
              try PersonalRoutineRequest.decodeExact(body) == request else { throw HouseholdFailure.invalid }
        try receipt?.validate(for: self)
    }
}

/// Revocation keeps no credential, private week or publish body, only an own-account receipt reference.
struct PersonalRoutineTombstone: Codable, Equatable, Identifiable, Sendable {
    let identity: [String]
    let requestId: UUID
    let expiresAt: Int64
    var unresolvedState: String
    var id: UUID { requestId }
    func validate() throws {
        guard identity.count == 4, identity.allSatisfy(HouseholdValidation.identifier), PersonalControlRequest.validInstant(expiresAt),
              ["awaiting", "pending", "unconfirmed"].contains(unresolvedState) else { throw HouseholdFailure.invalid }
    }
    func matches(_ session: HouseholdSession) -> Bool { identity == session.identity }
    func validate(_ receipt: PersonalRoutineReceipt, session: HouseholdSession) throws {
        try validate(); try receipt.validate()
        guard matches(session), receipt.requestId == requestId, receipt.scope.belongs(to: session),
              receipt.publishedAt <= expiresAt else { throw HouseholdFailure.changedIdentity }
    }
}
