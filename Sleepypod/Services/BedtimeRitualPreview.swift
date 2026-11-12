#if DEBUG
import SwiftUI

@MainActor private final class BedtimeRitualExampleStore: BedtimeRitualStoring {
    var saved: BedtimeRitualSavedState?
    func load(scope: String) throws -> BedtimeRitualSavedState? { saved }
    func save(_ state: BedtimeRitualSavedState) throws { saved = state }
}
@MainActor private final class BedtimeRitualExampleAccount { var current = true }

/// Exercise the production screen and session without network, Keychain or media effects.
struct BedtimeRitualPreview: View {
    @State private var workspace: BedtimeRitualWorkspace
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let index = arguments.firstIndex(of: "--bedtime-audio-fixture")
        let mode = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "ready"
        let storage = BedtimeRitualExampleStore()
        let account = BedtimeRitualExampleAccount()
        let scope = "bedtime-audio-synthetic-example"
        var session: BedtimeRitualSession?
        let next = BedtimeRitualSession(scope: scope, storage: storage, current: { account.current }, foreground: { true }, quiet: {
            if mode == "unavailable" { throw BedtimeRitualFailure.quietUnavailable }
            let now = Date.now
            return .init(scope: scope, generatedAt: now, expiresAt: now.addingTimeInterval(15), paused: mode == "quiet",
                         until: mode == "quiet" ? now.addingTimeInterval(3600) : nil)
        }, open: { _ in
            guard let attempt = session?.state?.attempt else { return false }
            if mode == "withdrawn" { account.current = false; return true }
            if mode == "notOpened" { return false }
            if mode != "pending", let callback = try? BedtimeRitualURL.callback(attempt, result: mode == "failed" ? "failed" : "completed") {
                session?.receive(callback)
            }
            return true
        })
        session = next; next.restore()
        if mode != "setup" {
            next.confirmSetup(.init(revision: UUID(), mode: .sleep,
                startShortcut: mode == "customSetup" ? "Nightfall A" : "Example Sleep",
                pauseShortcut: mode == "customSetup" ? "Quiet B" : "Example Pause",
                speakerName: mode == "customSetup" ? "Guest room speakers" : "Bedside HomePods", volumePercent: 35, durationMinutes: 60))
        }
        _workspace = State(initialValue: BedtimeRitualWorkspace {
            if mode == "connectionError" { throw BedtimeRitualFailure.accountChanged }
            return next
        })
    }
    var body: some View {
        NavigationStack { BedtimeRitualScreen(workspace: workspace, isExample: true) }
            .task { await workspace.prepare() }
    }
}
#endif
