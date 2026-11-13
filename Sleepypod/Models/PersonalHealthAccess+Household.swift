import CryptoKit
import Foundation
import FreeSleepKit

extension PersonalHealthIdentity {
    init(session: HouseholdSession) throws {
        try session.validate()
        guard let pod = UUID(uuidString: session.podId), let household = UUID(uuidString: session.householdId),
              let account = UUID(uuidString: session.accountId), let sleeper = UUID(uuidString: session.selfSleeperId) else {
            throw HouseholdFailure.invalid
        }
        self.init(podID: pod, householdID: household, accountID: account, sleeperID: sleeper)
    }
}

extension PersonalHealthAccess {
    init(record: HouseholdConnectionRecord, session: HouseholdSession) throws {
        guard session.capabilities.healthImport, record.identity == session, record.offlineBlocked != true,
              record.pending == nil, HouseholdValidation.secret(record.deviceSecret) else { throw HouseholdFailure.changedIdentity }
        try self.init(identity: PersonalHealthIdentity(session: session), connectionID: record.id,
                      credentialRevision: SHA256.hash(data: Data(record.deviceSecret.utf8)).map { String(format: "%02x", $0) }.joined(),
                      sessionRevision: session.sessionRevision, householdRevision: session.householdRevision,
                      assignmentRevision: session.assignmentRevision)
    }
}
