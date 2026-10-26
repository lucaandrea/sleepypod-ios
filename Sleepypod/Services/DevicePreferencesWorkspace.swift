import Foundation
import Observation

@MainActor @Observable final class DevicePreferencesWorkspace {
    private let client: any DevicePreferencesClient
    var draft: DevicePreferences?
    private(set) var saved: DevicePreferences?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var receipt: String?
    private(set) var mustReload = false
    private(set) var restarting = false
    private(set) var restartNeedsReconnect = false
    private(set) var restartReceipt: String?
    private(set) var source: SensorSourceSnapshot?
    private(set) var sourceReceivedAt: Date?
    private(set) var sourceError: String?
    private var sourceLoading = false
    private var sourceRevision = 0
    var dirty: Bool { draft != saved }
    init(client: any DevicePreferencesClient) { self.client = client }
    func load(discardDraft: Bool = false) async {
        guard !busy, !dirty || discardDraft else { return }
        busy = true
        defer { busy = false }
        do {
            let value = try await client.settings()
            try Task.checkCancellation()
            saved = value; draft = value; error = nil; receipt = nil; mustReload = false
            if restartNeedsReconnect { restartReceipt = "The controller responded to reconnect." }
            restartNeedsReconnect = false
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func save() async {
        guard !busy, !mustReload, let draft, let saved, draft != saved else { return }
        if let issue = draft.issue { error = issue; return }
        busy = true; error = nil; receipt = nil
        var sent = false
        defer { busy = false }
        do {
            let patch = draft.patch(from: saved)
            let current = try await client.settings()
            guard !patch.conflicts(original: saved.fields, current: current.fields) else {
                error = "A setting you edited changed on the Pod. Reload and review before saving."; mustReload = true; return
            }
            try Task.checkCancellation()
            sent = true
            try await client.save(patch)
            receipt = "Device settings saved."
            let value = try await client.settings()
            try Task.checkCancellation()
            self.saved = value; self.draft = value; mustReload = false
        } catch {
            mustReload = sent
            if receipt != nil { self.error = "The save was acknowledged, but settings could not be refreshed. Reload before continuing. \(error.localizedDescription)" }
            else if sent { self.error = "The save was not confirmed. Reload before retrying. \(error.localizedDescription)" }
            else if !Task.isCancelled { self.error = "No change was sent. \(error.localizedDescription)" }
        }
    }
    func refreshSource() async {
        guard !sourceLoading, !restartNeedsReconnect, !restarting else { return }
        let revision = sourceRevision
        sourceLoading = true
        defer { sourceLoading = false }
        do {
            let value = try await client.sensorSource()
            try Task.checkCancellation()
            guard !restartNeedsReconnect, sourceRevision == revision else { return }
            source = value; sourceReceivedAt = .now; sourceError = nil
        } catch { if !Task.isCancelled { sourceError = error.localizedDescription } }
    }
    // A main-service restart can end the connection before its receipt arrives; never replay it.
    func restart() async {
        guard saved != nil, !busy, !dirty, !mustReload, !restartNeedsReconnect, !Task.isCancelled else { return }
        busy = true; restarting = true; error = nil; restartReceipt = nil
        sourceRevision += 1; source = nil; sourceReceivedAt = nil
        defer { busy = false; restarting = false }
        do {
            let result = try await client.restart()
            if result.ok {
                restartReceipt = result.message
                restartNeedsReconnect = true; mustReload = true
            } else { error = result.message }
        } catch {
            self.error = "Restart response was not confirmed. Reconnect before trying again. \(error.localizedDescription)"
            restartNeedsReconnect = true; mustReload = true
        }
        if restartNeedsReconnect { source = nil; sourceReceivedAt = nil }
    }
}
