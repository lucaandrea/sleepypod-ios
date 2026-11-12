import Foundation

/// Health ownership follows the account and sleeper, never the current bed side.
public struct PersonalHealthIdentity: Codable, Equatable, Sendable {
    public let podID: UUID
    public let householdID: UUID
    public let accountID: UUID
    public let sleeperID: UUID

    public init(podID: UUID, householdID: UUID, accountID: UUID, sleeperID: UUID) {
        self.podID = podID; self.householdID = householdID
        self.accountID = accountID; self.sleeperID = sleeperID
    }
}

/// The host replaces this grant after authentication, credential or assignment changes.
/// It is held in memory only; credentials and session revisions do not own historical data.
public struct PersonalHealthAccess: Equatable, Sendable {
    public let identity: PersonalHealthIdentity
    public let connectionID: UUID
    public let credentialRevision: String
    public let sessionRevision: Int
    public let householdRevision: Int
    public let assignmentRevision: Int

    public init(identity: PersonalHealthIdentity, connectionID: UUID, credentialRevision: String,
                sessionRevision: Int, householdRevision: Int, assignmentRevision: Int) throws {
        guard credentialRevision.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              [sessionRevision, householdRevision, assignmentRevision].allSatisfy({ $0 > 0 && $0 <= 9_007_199_254_740_991 }) else {
            throw PersonalHealthFailure.invalid
        }
        self.identity = identity; self.connectionID = connectionID; self.credentialRevision = credentialRevision
        self.sessionRevision = sessionRevision; self.householdRevision = householdRevision; self.assignmentRevision = assignmentRevision
    }
}

enum PersonalHealthFailure: Error, LocalizedError, Equatable {
    case invalid, changed, anotherAccount, storage, confirmation

    var errorDescription: String? {
        switch self {
        case .invalid: "The saved Health import could not be verified. Your previous data has not been replaced."
        case .changed: "This account or its access changed. Reopen your personal Health page before continuing."
        case .anotherAccount: "Health is linked to another personal account on this device. Use your own iPhone or iPad, or review the local-data removal options."
        case .storage: "Unlock this device and try again. If saved Health data still cannot be read, it will not be overwritten."
        case .confirmation: "Confirm that this device’s Apple Health records belong to you before linking them to this account."
        }
    }
}

struct PersonalHealthArchive: Codable, Equatable {
    var version = 1
    var revision = UUID()
    let identity: PersonalHealthIdentity
    let enrolledAt: Date
    let consentVersion: Int
    var permissionRequested = false
    var automaticRefresh = false
    var history: HealthHistory?
    var selectedSource: String?

    func validate() throws {
        guard version == 1, consentVersion == 1, enrolledAt.timeIntervalSince1970.isFinite,
              enrolledAt.timeIntervalSince1970 > 0, !automaticRefresh || permissionRequested,
              permissionRequested || history == nil else { throw PersonalHealthFailure.invalid }
        guard let history else {
            guard selectedSource == nil else { throw PersonalHealthFailure.invalid }
            return
        }
        guard history.importedAt.timeIntervalSince1970.isFinite, history.importedAt >= enrolledAt,
              TimeZone(identifier: history.timeZone) != nil, history.ignoredSamples >= 0,
              history.sources.count <= 1000,
              Set(history.sources.map(\.id)).count == history.sources.count else { throw PersonalHealthFailure.invalid }
        for source in history.sources {
            guard !source.id.isEmpty, source.id.utf8.count <= 2048, !source.name.isEmpty, source.name.utf8.count <= 2048 else {
                throw PersonalHealthFailure.invalid
            }
            try validate(nights: source.nights, importedAt: history.importedAt)
        }
        if let watch = history.watchNights { try validate(nights: watch, importedAt: history.importedAt) }
        guard selectedSource.map({ selected in history.sources.contains { $0.id == selected } }) ?? history.sources.isEmpty else {
            throw PersonalHealthFailure.invalid
        }
    }

    private func validate(nights: [HealthHistory.Night], importedAt: Date) throws {
        guard nights.count <= 200_000, Set(nights.map(\.id)).count == nights.count else { throw PersonalHealthFailure.invalid }
        for night in nights {
            guard !night.id.isEmpty, night.id.utf8.count <= 256,
                  night.start.timeIntervalSince1970.isFinite, night.end.timeIntervalSince1970.isFinite,
                  night.start < night.end, night.end <= importedAt,
                  night.asleepMinutes.isFinite, night.asleepMinutes > 0,
                  night.asleepMinutes <= night.end.timeIntervalSince(night.start) / 60 + 0.01,
                  [night.deepMinutes, night.remMinutes].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= night.asleepMinutes }),
                  (night.deepMinutes ?? 0) + (night.remMinutes ?? 0) <= night.asleepMinutes + 0.01,
                  [night.restingHeartRate, night.hrv, night.respiratoryRate].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw PersonalHealthFailure.invalid
            }
        }
    }
}
