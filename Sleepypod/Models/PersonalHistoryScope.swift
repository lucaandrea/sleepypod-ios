import Foundation

struct PersonalHistoryScope: Codable, Equatable, Sendable {
    let podId: String
    let householdId: String
    let accountId: String
    let sleeperId: String
    let sessionRevision: Int
    let householdRevision: Int
    let assignmentRevision: Int

    func validate(for session: HouseholdSession) throws {
        guard [podId, householdId, accountId, sleeperId].allSatisfy(HouseholdValidation.identifier),
              [sessionRevision, householdRevision, assignmentRevision].allSatisfy(HouseholdValidation.revision) else { throw HouseholdFailure.invalid }
        guard podId == session.podId, householdId == session.householdId, accountId == session.accountId,
              sleeperId == session.selfSleeperId, sessionRevision == session.sessionRevision,
              householdRevision == session.householdRevision, assignmentRevision == session.assignmentRevision else { throw HouseholdFailure.changedIdentity }
    }
}
