import Foundation
import Observation

@MainActor @Observable final class PumpProtectionWorkspace {
    var draft: PumpProtectionSettings?
    private(set) var saved: PumpProtectionSettings?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var mustReload = false
    private let client: any PumpProtectionClient
    init(client: any PumpProtectionClient) { self.client = client }
    var changed: Bool { draft != saved }
    func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let value = try await client.settings()
            guard !Task.isCancelled else { return }
            saved = value; draft = value; error = nil; notice = nil; mustReload = false
        } catch { if !Task.isCancelled { self.error = error.localizedDescription; mustReload = true } }
    }
    func save() async {
        guard !busy, !mustReload, let draft, let saved, draft != saved else { return }
        busy = true; notice = nil; error = nil
        defer { busy = false }
        do {
            let patch = draft.patch(from: saved)
            try patch.validate()
            let value = try await client.save(patch)
            self.saved = value; self.draft = value; notice = "Saved to the controller."
        } catch {
            self.error = "\(error.localizedDescription) Reload saved settings before trying again; a request may have reached the controller."
            mustReload = true
        }
    }
}
