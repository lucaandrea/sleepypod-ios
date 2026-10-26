import Foundation
import Observation

@MainActor @Observable final class GestureBindingsWorkspace {
    private let client: any GestureBindingsClient
    private(set) var saved: GestureBindingsSnapshot?
    var editing: GestureDraft?
    private(set) var original: GestureBinding?
    private(set) var busy = false
    private(set) var mustReload = false
    private(set) var error: String?
    private(set) var receipt: String?
    init(client: any GestureBindingsClient) { self.client = client }
    func load(discard: Bool = false) async {
        guard !busy, editing == nil || discard else { return }
        busy = true; defer { busy = false }
        do {
            let value = try await client.settings(); try Task.checkCancellation()
            saved = value; editing = nil; original = nil; error = nil; receipt = nil; mustReload = false
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func open(_ side: Side, tap: CoverTap) {
        guard let saved, !busy, !mustReload else { return }
        original = saved.gestures.binding(side, tap: tap)
        editing = .init(side: side, tap: tap, original: original); error = nil; receipt = nil
    }
    func save() async { await mutate(removing: false) }
    func remove() async { await mutate(removing: true) }
    // The selected mapping is re-read before writing; unknown outcomes must be reconciled by Reload.
    private func mutate(removing: Bool) async {
        guard !busy, !mustReload, let editing, !removing || original != nil else { return }
        if !removing, let issue = editing.issue { error = issue; return }
        busy = true; error = nil; receipt = nil
        var sent = false
        defer { busy = false }
        do {
            let current = try await client.settings()
            guard current.gestures.binding(editing.side, tap: editing.tap) == original else {
                error = "This gesture changed on the Pod. Reload and review before saving."; mustReload = true; return
            }
            try Task.checkCancellation()
            sent = true
            if removing { try await client.remove(side: editing.side, tap: editing.tap) } else { try await client.save(editing) }
            receipt = removing ? "Gesture removed." : "Gesture saved."
            let value = try await client.settings(); try Task.checkCancellation()
            saved = value; self.editing = nil; original = nil
        } catch {
            mustReload = sent
            if receipt != nil { self.error = "Change was acknowledged, but readback failed. Reload before continuing. \(error.localizedDescription)" }
            else if sent { self.error = "Change was not confirmed. Reload before retrying. \(error.localizedDescription)" }
            else if !Task.isCancelled { self.error = "No change was sent. \(error.localizedDescription)" }
        }
    }
}
