import Foundation
import Observation

@MainActor @Observable
final class RemoteStageWorkspace {
    private(set) var side: Side
    private(set) var state: RemoteStageState?
    var draft: RemoteStageClassifier?
    var preview: RemoteStagePreview?
    var nights = 1
    var loading = false
    var saving = false
    var previewing = false
    var error: String?
    var previewError: String?
    var notice: String?
    private let client: any RemoteStageClient
    private var revision = 0
    private var previewRevision = 0
    private var previewed: RemoteStageClassifier?
    private var previewedNights: Int?
    var dirty: Bool { draft != state?.desired }
    var previewIsCurrent: Bool { draft != nil && previewed == draft && previewedNights == nights }
    var canSave: Bool { dirty && draft?.validation == nil && previewIsCurrent && !saving && !previewing && !loading }
    init(side: Side, client: any RemoteStageClient) { self.side = side; self.client = client }
    func load(side: Side? = nil) async {
        guard !saving else { return }
        revision += 1; let requested = revision
        previewRevision += 1; previewing = false
        if let side, side != self.side { self.side = side; state = nil; draft = nil; preview = nil; previewed = nil; previewedNights = nil }
        let selected = self.side
        loading = true; error = nil
        do {
            let result = try await client.state(side: selected)
            guard revision == requested, !Task.isCancelled else { return }
            state = result; draft = result.desired; preview = nil; previewed = nil; previewedNights = nil; notice = nil
        } catch { guard revision == requested, !Task.isCancelled else { return }; self.error = error.localizedDescription }
        if revision == requested { loading = false }
    }
    func refreshAcknowledgement() async {
        guard !saving, !dirty, state?.pending != nil else { return }
        let selected = side; let original = draft
        guard let result = try? await client.state(side: selected), side == selected, draft == original, !dirty else { return }
        state = result; draft = result.desired
    }
    func updatePreview() async {
        previewRevision += 1; let requested = previewRevision
        guard let candidate = draft, candidate.validation == nil else { preview = nil; previewed = nil; previewing = false; return }
        let selected = side; let selectedNights = nights
        previewing = true; previewError = nil
        do {
            let result = try await client.preview(side: selected, classifier: candidate, nights: selectedNights)
            guard previewRevision == requested, side == selected, draft == candidate, nights == selectedNights, !Task.isCancelled else { return }
            preview = result; previewed = candidate; previewedNights = selectedNights
        } catch {
            guard previewRevision == requested, !Task.isCancelled else { return }
            previewError = error.localizedDescription; previewed = nil
        }
        if previewRevision == requested { previewing = false }
    }
    func discard() { draft = state?.desired; error = nil }
    func save(_ replacement: RemoteStageClassifier?) async -> Bool {
        guard !saving, !loading, let original = state else { return false }
        if let validation = replacement?.validation { error = validation; return false }
        saving = true; error = nil; notice = nil
        defer { saving = false }
        do {
            let current = try await client.state(side: side)
            guard current.desired == original.desired, current.pending?.generation == original.pending?.generation,
                  current.provenance?.stageHash == original.provenance?.stageHash else {
                throw APIError.serverError(message: "These rules changed on another device. Your draft is kept; reload the current rules before saving.")
            }
            try await client.save(side: side, classifier: replacement)
            do {
                let result = try await client.state(side: side)
                state = result; draft = result.desired; previewed = nil
                notice = result.pending == nil ? "Stage rules saved." : "Saved. Waiting for the processor to adopt the change."
            } catch {
                notice = "The rules were saved, but the current state could not be refreshed. Reload before making another change."
                self.error = error.localizedDescription
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
