#if DEBUG
import CryptoKit
import SwiftUI

/// UI-only account with temporary encrypted storage and fake providers; never reads personal records or keys.
public struct PersonalAccountReportsExample: View {
    @State private var model: PersonalReportWorkspace?
    @State private var setupFailed = false
    private let directory = FileManager.default.temporaryDirectory.appending(path: "report-ui-" + UUID().uuidString)
    private let web = PersonalReportExampleWeb()
    public init() {}

    public var body: some View {
        NavigationStack {
            if let model {
                PersonalAccountReportsScreen(model: model, example: true, connect: {
                    MorningReportConnection(address: "https://example.invalid", transport: web, isCurrent: { model.available })
                })
            } else if setupFailed { ContentUnavailableView("Example unavailable", systemImage: "exclamationmark.triangle") }
            else { ProgressView("Preparing example…") }
        }.task { if model == nil { prepare() } }
            .onDisappear { model?.invalidate(); try? FileManager.default.removeItem(at: directory) }
    }

    private func prepare() {
        do {
            let scenario = UserDefaults.standard.string(forKey: "uiPersonalReportScenario") ?? "ready"
            let now = Date.now
            let identity = PersonalHealthIdentity(podID: UUID(), householdID: UUID(), accountID: UUID(), sleeperID: UUID())
            let access = try PersonalHealthAccess(identity: identity, connectionID: UUID(), credentialRevision: String(repeating: "a", count: 64),
                sessionRevision: 1, householdRevision: 1, assignmentRevision: 1)
            let key = SymmetricKey(size: .bits256)
            let snapshots = PrivateSnapshotStore(directory: directory, namespace: "report-ui", encryptionKey: { key })
            let store = PersonalReportStore(snapshots: snapshots)
            let evidence = Self.evidence(identity: identity, now: now)
            var archive = try store.open(identity)
            archive.preferences = .init(provider: .openai, model: "example-model", localAddress: "", monthlyLimit: 100)
            if ["saved", "offline", "followup"].contains(scenario) {
                let report = PersonalSleepReport(id: UUID(), createdAt: now, provider: .openai, model: "example-model",
                    source: evidence.sourceName, facts: evidence.facts, text: Self.answer,
                    inputTokens: nil, outputTokens: nil, comparison: evidence.comparison)
                archive.records = [.init(report: report, permission: .init(confirmedAt: now, provider: .openai,
                    requestedModel: "example-model", destination: IntelligenceProvider.openai.title, leavesDevice: true))]
            }
            _ = try store.update(archive, expectedRevision: archive.revision)
            if scenario == "storage" { try snapshots.write(["unreadable": true], scope: identity.reportScope) }
            let answer = Self.answer
            model = PersonalReportWorkspace(access: access, displayName: "Example sleeper", currentAccess: { access },
                requestPermitted: { scenario != "offline" }, store: store, keys: PersonalReportExampleKeys(),
                evidence: { _ in scenario == "empty" ? nil : evidence }, evidenceCurrent: { $0 == evidence },
                protectedData: { true }, allowedMode: { true }, generateModel: { request in
                    if scenario == "slow" { try await Task.sleep(for: .seconds(30)) }
                    if scenario == "error" { throw URLError(.notConnectedToInternet) }
                    return .init(text: answer, model: request.model, inputTokens: 100, outputTokens: 60)
                }, listModels: { _, _, _ in ["example-model"] })
        } catch { setupFailed = true }
    }

    private static let answer = """
    ### Your recent pattern
    **Your recorded nights are fairly consistent.** Unrecorded days remain unknown. [health.recent]

    ### What this means
    Recorded duration describes the selected source. It does not establish that a temperature change improved your sleep. [health.sleep]

    ### One optional experiment
    Keep a brief morning comfort note for a week, then review it alongside the next available recordings. No bed settings have changed.
    """

    private static func evidence(identity: PersonalHealthIdentity, now: Date) -> PersonalReportEvidence {
        let nights = (1...12).map { day -> HealthHistory.Night in
            let end = now.addingTimeInterval(Double(-day) * 86_400)
            return .init(id: "example-\(day)", start: end.addingTimeInterval(-8 * 3600), end: end,
                asleepMinutes: day % 3 == 0 ? 420 : 450, deepMinutes: 65, remMinutes: 80)
        }
        let source = HealthHistory.Source(id: "example", name: "Example Watch · synthetic observations", nights: nights)
        let history = HealthHistory(importedAt: now, timeZone: "America/Los_Angeles", sources: [source], ignoredSamples: 0)
        return .init(identity: identity, healthRevision: UUID(), sourceID: source.id, sourceName: source.name, importedAt: now,
            facts: HealthHistoryAnalyzer.facts(source: source, now: now, timeZone: TimeZone(identifier: history.timeZone)!),
            comparison: ReportSleepComparison.capture(source: source, history: history, now: now))
    }
}

@MainActor private final class PersonalReportExampleKeys: PersonalProviderKeys {
    private var keys: [IntelligenceProvider: String] = [.openai: "example-never-sent"]
    func read(_ provider: IntelligenceProvider) throws -> String { keys[provider] ?? "" }
    func save(_ value: String, for provider: IntelligenceProvider) throws { keys[provider] = value }
    func remove(_ provider: IntelligenceProvider) throws { keys[provider] = nil }
}

private actor PersonalReportExampleWeb: MorningReportSharingTransport {
    private var copy: MorningReportSharedCopy?
    func read(id: UUID) async throws -> MorningReportSharedCopy? { copy }
    func share(id: UUID, document: Data, expectedRevision: UUID?) async throws -> MorningReportSharedCopy {
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        let result = MorningReportSharedCopy(receipt: .init(id: id, revision: UUID(), deleted: false,
            createdAt: now, receivedAt: now, updatedAt: now), document: document)
        copy = result; return result
    }
    func withdraw(id: UUID, expectedRevision: UUID?) async throws -> MorningReportSharedCopy {
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        let result = MorningReportSharedCopy(receipt: .init(id: id, revision: UUID(), deleted: true,
            createdAt: nil, receivedAt: now, updatedAt: now), document: nil)
        copy = result; return result
    }
}
#endif
