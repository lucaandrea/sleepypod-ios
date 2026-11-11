import Foundation

/// Receipts describe controller acceptance; none establishes physical movement or attendance.
struct ArrangementRestartReceipt: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case requested, submitted, unconfirmed }
    let operationId: String
    let requestId: String
    let state: State
    let requestedAt: Int64
    let resultAt: Int64?
    let hardware: String
    let replayAllowed: Bool

    static let fields: Set<String> = ["operationId", "requestId", "state", "requestedAt", "resultAt", "hardware", "replayAllowed"]
    func validate() throws {
        guard [operationId, requestId].allSatisfy(HouseholdValidation.identifier),
              PersonalControlRequest.validInstant(requestedAt), hardware == "held_for_runtime_recovery", !replayAllowed,
              (state == .requested) == (resultAt == nil),
              resultAt.map({ PersonalControlRequest.validInstant($0) && $0 >= requestedAt }) ?? true else { throw HouseholdFailure.invalid }
    }
}

struct ArrangementRecoveryReceipt: Codable, Equatable, Sendable {
    let operationId: String
    let requestId: String
    let reviewId: String
    let state: String
    let completedAt: Int64
    let admissionRevision: Int
    let epochId: String
    let recordingStartsAt: Int64
    let hardware: String
    let physicalMovement: String

    static let fields: Set<String> = ["operationId", "requestId", "reviewId", "state", "completedAt", "admissionRevision", "epochId", "recordingStartsAt", "hardware", "physicalMovement"]
    func validate() throws {
        guard [operationId, requestId, reviewId, epochId].allSatisfy(HouseholdValidation.identifier),
              state == "completed", HouseholdValidation.revision(admissionRevision),
              [completedAt, recordingStartsAt].allSatisfy(PersonalControlRequest.validInstant),
              recordingStartsAt <= completedAt, hardware == "admission_released", physicalMovement == "not_requested" else { throw HouseholdFailure.invalid }
    }
}

struct ArrangementCancellationReceipt: Codable, Equatable, Sendable {
    let operationId: String
    let requestId: String
    let reviewId: String
    let state: String
    let completedAt: Int64
    let admissionRevision: Int
    let controlDigest: String
    let arrangement: String
    let hardware: String
    let physicalMovement: String

    static let fields: Set<String> = ["operationId", "requestId", "reviewId", "state", "completedAt", "admissionRevision", "controlDigest", "arrangement", "hardware", "physicalMovement"]
    func validate() throws {
        guard [operationId, requestId, reviewId].allSatisfy(HouseholdValidation.identifier),
              state == "cancelled", HouseholdValidation.revision(admissionRevision),
              PersonalControlRequest.validInstant(completedAt), ArrangementMaintenanceValidation.digest(controlDigest),
              arrangement == "solo-anywhere", hardware == "admission_released", physicalMovement == "not_requested" else { throw HouseholdFailure.invalid }
    }
}

enum ArrangementMaintenanceValidation {
    static func digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func owner(_ current: HouseholdSession, anchoredTo original: HouseholdSession) throws {
        try current.validate(); try original.validate()
        guard current.identity == original.identity, current.role == "owner", original.role == "owner" else { throw HouseholdFailure.changedIdentity }
    }
    static func fresh(_ observedAt: Int64, now: Int64, maximumAge: Int64 = 15_000) -> Bool {
        PersonalControlRequest.validInstant(observedAt) && PersonalControlRequest.validInstant(now)
            && observedAt <= now && now - observedAt <= maximumAge
    }
    static func optionalKeys(_ object: Any?, fields: Set<String>) throws {
        guard let object else { throw HouseholdFailure.invalid }
        if !(object is NSNull) { try ArrangementJSON.keys(object, fields) }
    }
}
