import Foundation

struct BackupAlarmRecord: Codable, Equatable, Sendable {
    let version: Int
    let id: UUID
    let owner: String
    let side: Side
    let at: Date
    let podRevision: String
    let createdAt: Date

    func validate() throws {
        guard version == 1, owner.count == 64, NextAlarmState.validRevision(owner),
              NextAlarmState.validRevision(podRevision), at.timeIntervalSince1970.isFinite,
              createdAt.timeIntervalSince1970.isFinite, at > createdAt else { throw BackupAlarmFailure.invalid }
    }
}

enum BackupAlarmExpectation: Equatable, Sendable {
    case absent
    case existing(BackupAlarmRecord)
}

struct BackupSystemAlarm: Equatable, Sendable {
    let id: UUID
    let at: Date?
    let state: String
}

enum BackupAlarmFailure: LocalizedError {
    case invalid, stale, access, changed, storage, reviewedAlarmChanged
    var errorDescription: String? {
        switch self {
        case .invalid: "This phone's saved backup could not be verified."
        case .stale: "Refresh the Pod's next alarm before adding a backup."
        case .access: "Allow alarms for sleepypod in Settings to add a phone backup."
        case .changed: "The connected account or Pod changed. No new backup was confirmed."
        case .storage: "The backup receipt could not be saved. No new alarm was requested."
        case .reviewedAlarmChanged: "The phone backup changed or could not be verified. Review the phone alarm again before replacing it."
        }
    }
}

@MainActor protocol BackupAlarmClient {
    func requestAccess() async throws -> Bool
    func alarms() throws -> [BackupSystemAlarm]
    func schedule(id: UUID, at: Date) async throws
    func cancel(id: UUID) throws
}

/// An explicit one-occurrence backup follows the Pod's absolute instant, including DST.
enum BackupAlarmPolicy {
    static func candidate(_ plan: NextAlarmState, receivedAt: Date?, now: Date) throws -> Date {
        try plan.validate(side: plan.side)
        guard let receivedAt, receivedAt <= now.addingTimeInterval(5), now.timeIntervalSince(receivedAt) <= 90,
              plan.state == "scheduled", plan.execution == nil, plan.canChange,
              let alarm = plan.alarm, let at = NextAlarmState.instant(alarm.at),
              at > now.addingTimeInterval(60), at <= now.addingTimeInterval(8 * 86_400) else { throw BackupAlarmFailure.stale }
        return at
    }
}
