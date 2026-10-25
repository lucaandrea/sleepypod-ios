import Foundation
import Observation

@MainActor @Observable
final class PreferencesWorkspace {
    private(set) var snapshot: PreferencesSnapshot?
    var draft: PodPreferences?
    private(set) var busy = false
    private(set) var failure: String?
    private(set) var message: String?
    private var revision = 0
    var dirty: Bool { draft != snapshot?.preferences }
    var valid: Bool { draft?.valid == true && snapshot?.timeZones.contains(draft?.timeZone ?? "") == true }
    func resetDraft() { if !busy { draft = snapshot?.preferences; message = nil } }
    func invalidate() { revision += 1; snapshot = nil; draft = nil; busy = false; failure = nil; message = nil }
    func load(using fetch: () async throws -> PreferencesSnapshot) async {
        guard !busy else { return }
        let requestRevision = revision
        busy = true; failure = nil; message = nil
        defer { if revision == requestRevision { busy = false } }
        do {
            let result = try await fetch()
            guard !Task.isCancelled, requestRevision == revision else { return }
            snapshot = result; draft = result.preferences
        } catch { if !Task.isCancelled && requestRevision == revision { failure = error.localizedDescription } }
    }
    func save(using send: (PreferenceChange) async throws -> PreferencesSnapshot) async -> PreferencesSnapshot? {
        guard !busy, valid, dirty, let snapshot, let draft else { return nil }
        let requestRevision = revision
        busy = true; failure = nil; message = nil
        defer { if revision == requestRevision { busy = false } }
        do {
            let result = try await send(.init(podID: snapshot.podID, expected: snapshot.preferences, preferences: draft.normalized))
            guard !Task.isCancelled, requestRevision == revision else { return nil }
            guard result.podID == snapshot.podID else { throw PodError.message("The Pod identity changed. Reload settings before continuing.") }
            self.snapshot = result; self.draft = result.preferences; message = "Device settings saved."
            return result
        } catch { if !Task.isCancelled && requestRevision == revision { failure = error.localizedDescription }; return nil }
    }
}
