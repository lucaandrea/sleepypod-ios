import Foundation

extension PersonalHealthIdentity {
    /// Stable across side, session and credential changes; never shared with the owner workspace.
    var reportScope: String {
        [podID, householdID, accountID, sleeperID].map { $0.uuidString.lowercased() }.joined(separator: "|")
    }
}

struct PersonalReportPreferences: Codable, Equatable {
    var provider: IntelligenceProvider = .apple
    var model = IntelligenceProvider.apple.models[0]
    var localAddress = ""
    var monthlyLimit = 100

    func validate() throws {
        guard (0...1000).contains(monthlyLimit), localAddress.utf8.count <= 2048,
              provider == .apple ? model == IntelligenceProvider.apple.models[0] : IntelligenceProvider.validModel(model) else {
            throw PersonalReportFailure.invalid
        }
        if provider == .ollama, !localAddress.isEmpty { _ = try ConnectionEndpoint.url(localAddress) }
    }

    var destination: String { provider == .ollama ? localAddress : provider.title }
}

struct PersonalReportPermission: Codable, Equatable {
    let confirmedAt: Date
    let provider: IntelligenceProvider
    let requestedModel: String
    let destination: String
    let leavesDevice: Bool
}

struct PersonalReportRecord: Codable, Equatable, Identifiable {
    var report: PersonalSleepReport
    let permission: PersonalReportPermission
    var answerPermissions: [PersonalReportPermission] = []
    var id: UUID { report.id }
}

struct PersonalReportArchive: Codable, Equatable {
    var version = 1
    var revision = UUID()
    let identity: PersonalHealthIdentity
    var preferences = PersonalReportPreferences()
    var usageMonth = ""
    var attempts = 0
    var records: [PersonalReportRecord] = []

    func validate(now: Date) throws {
        try preferences.validate()
        guard version == 1, (0...1000).contains(attempts),
              usageMonth.isEmpty || usageMonth.range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil,
              records.count <= 30, Set(records.map(\.id)).count == records.count else { throw PersonalReportFailure.invalid }
        for record in records {
            _ = try MorningReportTransfer.document(record.report, now: now)
            guard !record.report.facts.isEmpty, record.report.comparison?.isValid != false,
                  record.answerPermissions.count == (record.report.followUps?.count ?? 0) else { throw PersonalReportFailure.invalid }
            try validate(record.permission, provider: record.report.provider, completed: record.report.createdAt)
            for (permission, answer) in zip(record.answerPermissions, record.report.followUps ?? []) {
                try validate(permission, provider: answer.provider, completed: answer.createdAt)
            }
        }
    }

    private func validate(_ permission: PersonalReportPermission, provider: IntelligenceProvider, completed: Date) throws {
        guard permission.provider == provider, permission.leavesDevice == provider.leavesDevice,
              permission.confirmedAt.timeIntervalSince1970.isFinite, permission.confirmedAt > .distantPast,
              permission.confirmedAt <= completed, !permission.destination.isEmpty, permission.destination.utf8.count <= 2048,
              provider == .apple ? permission.requestedModel == IntelligenceProvider.apple.models[0]
                : IntelligenceProvider.validModel(permission.requestedModel) else { throw PersonalReportFailure.invalid }
        if provider == .ollama { _ = try ConnectionEndpoint.url(permission.destination) }
        else if permission.destination != provider.title { throw PersonalReportFailure.invalid }
    }
}

enum PersonalReportFailure: Error, LocalizedError, Equatable {
    case invalid, changed, storage, consent, evidence, limit
    var errorDescription: String? {
        switch self {
        case .invalid: "The saved personal report could not be verified. It has not been replaced."
        case .changed: "Your account, evidence or model settings changed. Reopen this page before creating a report."
        case .storage: "Unlock this device and try reading your saved reports again. An unreadable copy will not be replaced."
        case .consent: "Review and confirm this request before sending your evidence to the selected provider."
        case .evidence: "Connect your own Health history and choose a sleep source before creating a report."
        case .limit: "This personal account has reached its monthly model request limit on this device."
        }
    }
}
