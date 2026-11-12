#if DEBUG
import CryptoKit
import SwiftUI

/// Synthetic UI fixture: temporary ciphertext and an ephemeral key; no Health, Keychain, Pod or provider access.
public struct PersonalHealthExample: View {
    @State private var model: PersonalHealthWorkspace?
    @State private var setupFailed = false
    private let directory = FileManager.default.temporaryDirectory.appending(path: "health-ui-" + UUID().uuidString)
    public init() {}

    public var body: some View {
        NavigationStack {
            if let model { PersonalHealthScreen(model: model, example: true) }
            else if setupFailed { ContentUnavailableView("Example unavailable", systemImage: "exclamationmark.triangle") }
            else { ProgressView("Preparing example…") }
        }
        .task { if model == nil { prepare() } }
        .onDisappear { model?.invalidate(); try? FileManager.default.removeItem(at: directory) }
    }

    private func prepare() {
        do {
            let scenario = UserDefaults.standard.string(forKey: "uiPersonalHealthScenario") ?? "consent"
            let now = Date.now
            let identity = PersonalHealthIdentity(podID: UUID(), householdID: UUID(), accountID: UUID(), sleeperID: UUID())
            let access = try PersonalHealthAccess(identity: identity, connectionID: UUID(), credentialRevision: String(repeating: "a", count: 64),
                sessionRevision: 1, householdRevision: 1, assignmentRevision: 1)
            let key = SymmetricKey(size: .bits256)
            let snapshots = PrivateSnapshotStore(directory: directory, namespace: "health-ui", encryptionKey: { key })
            let store = PersonalHealthStore(snapshots: snapshots)
            if scenario != "consent" {
                let owner = scenario == "other" ? PersonalHealthIdentity(podID: UUID(), householdID: UUID(), accountID: UUID(), sleeperID: UUID()) : identity
                var archive = try store.enroll(identity: owner, at: now.addingTimeInterval(-86_400))
                archive.permissionRequested = true
                archive.history = Self.history(now: now.addingTimeInterval(-3600), empty: scenario == "empty")
                archive.selectedSource = archive.history?.sources.first?.id
                _ = try store.update(archive, expectedRevision: archive.revision)
            }
            if scenario == "storage" { try snapshots.write(["unreadable": true], scope: "device-health-enrollment") }
            model = PersonalHealthWorkspace(access: access, displayName: "Example sleeper", store: store,
                currentAccess: { access }, importPermitted: { scenario != "offline" }, protectedDataAvailable: { true },
                authorizeHistory: {}, readHistory: {
                    if scenario == "slow" { try await Task.sleep(for: .seconds(15)) }
                    if scenario == "failure" { throw PersonalHealthFailure.storage }
                    return Self.history(now: .now, empty: scenario == "empty")
                }, allowedMode: { true })
        } catch { setupFailed = true }
    }

    private static func history(now: Date, empty: Bool) -> HealthHistory {
        .init(importedAt: now, timeZone: "America/Los_Angeles", sources: empty ? [] : [
            .init(id: "example.watch", name: "Example Watch", nights: (1...3).map { day in
                let end = now.addingTimeInterval(Double(-day) * 86_400)
                return .init(id: "example-\(day)", start: end.addingTimeInterval(-8 * 3600), end: end,
                             asleepMinutes: 450, deepMinutes: 70, remMinutes: 85)
            }),
            .init(id: "example.original", name: "Example original sleep history imported from a previous bed", nights: (1...2).map { day in
                let end = now.addingTimeInterval(Double(-day) * 86_400)
                return .init(id: "original-\(day)", start: end.addingTimeInterval(-8 * 3600), end: end,
                             asleepMinutes: 440, deepMinutes: 65, remMinutes: 80)
            })
        ], ignoredSamples: 0, watchNights: [])
    }
}
#endif
