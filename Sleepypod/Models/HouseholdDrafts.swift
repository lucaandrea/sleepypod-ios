import Foundation

struct HouseholdPreferences: Codable, Equatable, Sendable {
    var displayUnit: String
    var preferredTemperatureF: Int
    var comfort: String
    var shareWakeTime: Bool
    let cloudAnalysisConsent: Bool
    static let blank = Self(displayUnit: "F", preferredTemperatureF: 74, comfort: "balanced", shareWakeTime: false, cloudAnalysisConsent: false)
    func validate() throws {
        guard ["F", "C"].contains(displayUnit), (55...110).contains(preferredTemperatureF),
              ["warm_sleeper", "balanced", "cold_sleeper"].contains(comfort), !cloudAnalysisConsent else { throw HouseholdFailure.invalid }
    }
}

struct HouseholdPreferencesResponse: Codable, Equatable, Sendable {
    let sleeperId: String
    let revision: Int
    let preferences: HouseholdPreferences
    func validate(for session: HouseholdSession) throws {
        guard sleeperId == session.selfSleeperId, HouseholdValidation.revision(revision) else { throw HouseholdFailure.changedIdentity }
        try preferences.validate()
    }
}

struct HouseholdRoutine: Codable, Equatable, Identifiable, Sendable {
    let dayOfWeek: DayOfWeek
    var draft: BedtimeRoutineDraft
    var id: DayOfWeek { dayOfWeek }
    static func validate(_ routines: [Self]) throws {
        guard routines.count <= 7, Set(routines.map(\.dayOfWeek)).count == routines.count else { throw HouseholdFailure.invalid }
        try BedtimeRoutineTime.validateWeek(routines.map { ($0.dayOfWeek, $0.draft) })
    }
}

struct HouseholdRoutinesResponse: Codable, Equatable, Sendable {
    let sleeperId: String
    let revision: Int
    let status: String
    let routines: [HouseholdRoutine]
    func validate(for session: HouseholdSession) throws {
        guard sleeperId == session.selfSleeperId, HouseholdValidation.revision(revision) else { throw HouseholdFailure.changedIdentity }
        guard status == "draft_only" else { throw HouseholdFailure.preparationOnly }
        try HouseholdRoutine.validate(routines)
    }
}

struct HouseholdInvitation: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let kind: String
    let expiresAt: String
    let status: String
    func validate() throws {
        guard HouseholdValidation.identifier(id), ["new_person", "own_device"].contains(kind),
              ["pending", "claimed", "expired", "revoked"].contains(status), SensorObservation.date(expiresAt) != nil else { throw HouseholdFailure.invalid }
    }
}
struct HouseholdInvitationReceipt: Codable, Sendable {
    let id: String
    let invitation: String
    let kind: String
    let expiresAt: String
}
struct HouseholdDevice: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let createdAt: String
    let current: Bool
    func validate() throws {
        guard HouseholdValidation.identifier(id), HouseholdValidation.name(name), SensorObservation.date(createdAt) != nil else { throw HouseholdFailure.invalid }
    }
}
