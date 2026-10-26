import Foundation
import Observation

@MainActor @Observable final class PersonalComfortWorkspace {
    private(set) var client: (any PersonalComfortClient)?
    private(set) var side: Side = .left
    private var generation = 0
    private var ownerRevision: [String] = []
    private(set) var status: PersonalComfortStatus?
    private(set) var reports: ComfortNightList?
    private(set) var loading = false
    private(set) var saving = false
    private(set) var error: String?
    private(set) var reportsError: String?
    private(set) var notice: String?
    private(set) var requiresReload = false
    func configure(client: (any PersonalComfortClient)?, side: Side) {
        generation += 1; self.client = client; self.side = side; ownerRevision = OwnerConnection.revision; status = nil; reports = nil
        error = nil; reportsError = nil; notice = nil; loading = false; saving = false; requiresReload = false
    }
    func invalidate() { generation += 1; if saving { requiresReload = true }; status = nil; reports = nil; loading = false; saving = false }
    func load(userInitiated: Bool = false) async {
        guard ownerRevision == OwnerConnection.revision, !Task.isCancelled, !loading, !saving, !requiresReload || userInitiated else { return }
        guard let client else { error = "Connect to a controller to read personal comfort."; return }
        let operation = generation, owner = OwnerConnection.revision, selectedSide = side; loading = true
        defer { if generation == operation { loading = false } }
        do {
            let result = try await client.status(side: selectedSide); try result.validate(side: selectedSide)
            guard generation == operation, owner == OwnerConnection.revision, !Task.isCancelled else { return }
            status = result; error = nil; requiresReload = false
            if result.features.nightReports == true {
                do {
                    let result = try await client.reports(side: selectedSide); try result.validate(side: selectedSide)
                    guard generation == operation, owner == OwnerConnection.revision, !Task.isCancelled else { return }
                    reports = result; reportsError = nil
                } catch { if generation == operation { reports = nil; reportsError = error.localizedDescription } }
            } else { reports = nil; reportsError = nil }
        } catch { if generation == operation { status = nil; reports = nil; self.error = error.localizedDescription } }
    }
    /// Recheck the original configuration before dispatch; never replay an uncertain write.
    func save(_ draft: PersonalComfortConfig, original: PersonalComfortConfig) async -> Bool {
        guard ownerRevision == OwnerConnection.revision, !Task.isCancelled, let client, !saving, !loading, status?.state?.config == original, error == nil else { return false }
        let operation = generation, owner = OwnerConnection.revision, selectedSide = side; saving = true; notice = nil
        defer { if generation == operation { saving = false } }
        do {
            try draft.validate()
            let current = try await client.status(side: selectedSide); try current.validate(side: selectedSide)
            guard generation == operation, owner == OwnerConnection.revision, !Task.isCancelled else { return false }
            guard current.state?.config == original else { throw APIError.serverError(message: "Personal comfort changed on another device. Reload and review the new configuration.") }
            guard current.fault == nil || draft.mode == "off", draft.sensorAware != true || current.features.sensorAware,
                  draft.followBedtime != true || current.features.followBedtime else {
                throw APIError.serverError(message: current.fault ?? "This controller does not support the selected comfort guards.")
            }
            let result = try await client.configure(side: selectedSide, config: draft); try result.validate(side: selectedSide)
            guard generation == operation, owner == OwnerConnection.revision, !Task.isCancelled else { return false }
            guard result.state?.config == draft else { throw APIError.serverError(message: "The returned configuration does not match. Refresh before trying again.") }
            status = result; notice = "Personal comfort saved. Preview sends no bed commands."; return true
        } catch {
            if generation == operation { self.error = error.localizedDescription + " Refresh before retrying."; requiresReload = true; status = nil; reports = nil }
            return false
        }
    }
    /// A mode-only stop preserves the server's latest thresholds, learning state and manual pause.
    func stopPreview() async -> Bool {
        guard ownerRevision == OwnerConnection.revision, !Task.isCancelled, let client, let status, let state = status.state, !saving, !loading, !requiresReload, error == nil else { return false }
        if status.features.modeOnly != true {
            var draft = state.config.editable; draft.mode = "off"
            return await save(draft, original: state.config)
        }
        let operation = generation, owner = OwnerConnection.revision, selectedSide = side
        saving = true; notice = nil; requiresReload = true
        defer { if generation == operation { saving = false } }
        do {
            let result = try await client.mode(side: selectedSide, mode: "off"); try result.validate(side: selectedSide)
            guard generation == operation, owner == OwnerConnection.revision, !Task.isCancelled else {
                if generation == operation, owner == OwnerConnection.revision {
                    self.status = nil; self.error = "The comfort change was interrupted. Refresh before retrying."
                }
                return false
            }
            guard result.state?.config.mode == "off" else { throw APIError.serverError(message: "The controller did not confirm that personal comfort stopped.") }
            self.status = result; requiresReload = false; notice = "Personal comfort stopped."; return true
        } catch {
            if generation == operation { self.error = error.localizedDescription + " Refresh before retrying."; requiresReload = true; self.status = nil; reports = nil }
            return false
        }
    }
    func saveFeedback(_ input: PersonalComfortFeedback) async -> Bool {
        guard ownerRevision == OwnerConnection.revision, !Task.isCancelled, let client, !saving, !loading, let status, error == nil, status.fault == nil else { return false }
        let operation = generation, owner = OwnerConnection.revision, selectedSide = side; saving = true; notice = nil
        defer { if generation == operation { saving = false } }
        do {
            try input.validate(deviceDate: status.deviceDate)
            let result = try await client.feedback(side: selectedSide, input: input); try result.validate(side: selectedSide)
            guard generation == operation, owner == OwnerConnection.revision, !Task.isCancelled else { return false }
            self.status = result; notice = "Check-in saved."; return true
        } catch {
            if generation == operation { self.error = error.localizedDescription + " Refresh before retrying."; requiresReload = true; self.status = nil; reports = nil }
            return false
        }
    }
}

@MainActor @Observable final class ComfortNightWorkspace {
    let client: any PersonalComfortClient
    let side: Side
    let id: String
    private var generation = 0
    private(set) var detail: ComfortNightDetail?
    private(set) var after: Int?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var notice: String?
    init(client: any PersonalComfortClient, side: Side, id: String) { self.client = client; self.side = side; self.id = id }
    func invalidate() { generation += 1; detail = nil; after = nil; busy = false }
    func load(after requested: Int? = nil) async {
        guard !busy else { return }
        let operation = generation, owner = OwnerConnection.revision, digest = detail?.summary.digest
        busy = true; defer { if generation == operation { busy = false } }
        do {
            let result = try await client.report(side: side, id: id, after: requested); try result.validate(id: id, after: requested)
            guard generation == operation, owner == OwnerConnection.revision, !Task.isCancelled else { return }
            if requested != nil, digest != result.summary.digest {
                detail = nil; after = nil; error = "This report changed while paging. Refresh from the first observations before reviewing."; return
            }
            detail = result; after = requested; error = nil
        } catch { if generation == operation { self.error = error.localizedDescription; detail = nil; after = nil } }
    }
    /// The server binds each review to its evidence digest and expected prior review.
    func save(_ input: ComfortReviewInput) async -> Bool {
        guard !busy, let detail, error == nil, input.side == side else { return false }
        let operation = generation, owner = OwnerConnection.revision; busy = true; notice = nil
        defer { if generation == operation { busy = false } }
        do {
            try input.validate(report: detail)
            let result = try await client.review(input)
            guard generation == operation, owner == OwnerConnection.revision, !Task.isCancelled else { return false }
            guard result.digest == input.digest, result.outcome == input.outcome, result.confirmedActualNight == input.confirmedActualNight,
                  result.note == input.note.trimmingCharacters(in: .whitespacesAndNewlines) else { throw APIError.serverError(message: "The review receipt did not match. Refresh this report before retrying.") }
            // Re-read the authoritative count and review; a failed read never resends the review.
            self.detail = nil; after = nil; notice = "Review saved. Active adjustments remain unavailable."
            let refreshed = try await client.report(side: side, id: id, after: nil); try refreshed.validate(id: id)
            guard generation == operation, owner == OwnerConnection.revision, !Task.isCancelled else { return false }
            self.detail = refreshed; return true
        } catch { if generation == operation { self.error = error.localizedDescription; self.detail = nil; after = nil }; return false }
    }
}
