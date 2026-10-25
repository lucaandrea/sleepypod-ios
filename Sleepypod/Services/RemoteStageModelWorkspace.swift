import Foundation
import Observation

@MainActor @Observable final class RemoteStageModelWorkspace {
    private(set) var side: Side
    private(set) var state: RemoteStageModelState?
    private(set) var prepared: RemoteStageModelDocument?
    private(set) var filename: String?
    var choice: Int?
    var nights = 7
    private(set) var preview: RemoteStageModelPreview?
    private(set) var busy = false
    private(set) var previewing = false
    var error: String?
    var notice: String?
    private let client: any RemoteStageModelClient
    private var revision = 0
    private var previewRevision = 0
    var chosen: RemoteStageModelItem? { state?.library.first { $0.id == choice } }
    var canApply: Bool { !busy && state?.supported == true && (choice == nil ? state?.selection?.active == true : chosen != nil && chosen?.active == false) }
    init(side: Side, client: any RemoteStageModelClient) { self.side = side; self.client = client }
    func load(side: Side? = nil) async {
        guard !busy else { return }
        revision += 1; let request = revision
        clearPreview()
        if let side, side != self.side { self.side = side; state = nil; discardFile(); choice = nil; preview = nil }
        let selected = self.side
        busy = true; error = nil
        defer { if revision == request { busy = false } }
        do {
            let result = try await client.state(side: selected)
            guard revision == request, !Task.isCancelled else { return }
            state = result; choice = result.library.first(where: \.active)?.id
        } catch { if revision == request, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func prepare(_ url: URL) async {
        guard !busy else { return }
        busy = true; error = nil; notice = nil; discardFile()
        defer { busy = false }
        do {
            let document = try await Task.detached(priority: .userInitiated) { try RemoteStageModelDocument.readFile(url) }.value
            guard !Task.isCancelled else { return }
            prepared = document; filename = url.lastPathComponent
        } catch { self.error = error.localizedDescription }
    }
    func discardFile() { prepared = nil; filename = nil; preview = nil; previewRevision += 1; previewing = false }
    func upload() async {
        guard !busy, state?.supported == true, let prepared else { return }
        busy = true; error = nil; notice = nil
        defer { busy = false }
        do {
            let id = try await client.upload(side: side, document: prepared)
            discardFile()
            notice = "Model saved to this side’s library. Select it and choose Use this model to activate it."
            do { state = try await client.state(side: side); choice = id }
            catch { self.error = "The upload succeeded, but the library could not refresh. Reload before continuing. " + error.localizedDescription }
        } catch { self.error = error.localizedDescription }
    }
    /// Recheck the observed selection so another device's choice is not silently replaced.
    func apply() async {
        guard canApply, let original = state else { return }
        let selectedID = choice
        busy = true; error = nil; notice = nil; previewRevision += 1; preview = nil; previewing = false
        defer { busy = false }
        do {
            let current = try await client.state(side: side)
            guard current.selection == original.selection else {
                throw APIError.serverError(message: "The active model changed on another device. Reload the library before applying your choice.")
            }
            if let selectedID {
                guard current.library.contains(where: { $0.id == selectedID }) else { throw APIError.serverError(message: "This model is no longer in the library. Reload before continuing.") }
                try await client.select(side: side, id: selectedID, active: true)
            } else { try await client.setActive(side: side, active: false) }
            notice = selectedID == nil ? "Rules selected for this side." : "Model selected for this side. Rules remain the fallback."
            do { state = try await client.state(side: side) }
            catch { self.error = "The choice was saved, but the current state could not refresh. Reload before making another change. " + error.localizedDescription }
        } catch { self.error = error.localizedDescription }
    }
    func previewModel() async {
        guard !busy, state?.previewSupported == true, prepared != nil || state?.selection?.model != nil else { return }
        previewRevision += 1; let request = previewRevision
        let selected = side; let document = prepared; let window = nights
        previewing = true; error = nil; preview = nil
        do {
            let result = try await client.preview(side: selected, document: document, nights: window)
            guard previewRevision == request, side == selected, nights == window, prepared == document, !Task.isCancelled else { return }
            preview = result
        } catch { if previewRevision == request, !Task.isCancelled { self.error = error.localizedDescription } }
        if previewRevision == request { previewing = false }
    }
    func clearPreview() { previewRevision += 1; preview = nil; previewing = false }
}
