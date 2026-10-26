import Foundation
import Observation

@MainActor @Observable final class BiometricBacktestPreparation {
    let side: Side
    let experiment: BiometricExperiment
    let client: any BiometricDatasetsServing
    private(set) var draft: BiometricBacktestSubmissionDraft?
    private(set) var overview: BiometricProfileOverview?
    private(set) var observedAt: Date?
    private(set) var page: BiometricProfilePage?
    private(set) var cursor: BiometricProfilePage.Cursor?
    private(set) var refreshing = false
    private(set) var loading = false
    private(set) var error: String?
    private(set) var pageError: String?
    init(side: Side, experiment: BiometricExperiment, client: any BiometricDatasetsServing) { self.side = side; self.experiment = experiment; self.client = client }
    func fresh(at now: Date = .now) -> Bool {
        guard let observedAt, error == nil, overview != nil else { return false }
        let age = now.timeIntervalSince(observedAt); return age >= 0 && age <= 15
    }
    /// Polling only reads the controller. A changed baseline never rewrites the selected candidate.
    func refresh() async {
        guard !refreshing else { return }; refreshing = true
        defer { refreshing = false }
        do {
            let current = try await client.evaluationOverview(side: side)
            guard current.desired.binding.side == side, current.desired.binding.generation >= 0,
                  experiment.side == side, experiment.validIdentity else { throw BiometricBacktestInput.error("The selected side is unavailable for a new evaluation.") }
            if draft == nil {
                let inputs = try await client.dataset(id: experiment.datasetId)
                guard inputs.side == side, inputs.validIdentity, inputs.id == experiment.datasetId, inputs.available, inputs.manifest.supported else { throw BiometricBacktestInput.error("The selected inputs are unavailable for a new evaluation.") }
                guard !Task.isCancelled else { return }
                draft = .init(experiment: experiment, dataset: inputs)
            }
            guard !Task.isCancelled else { return }
            overview = current; observedAt = .now; error = nil
        } catch { if !Task.isCancelled { observedAt = nil; self.error = error.localizedDescription } }
    }
    func load(_ cursor: BiometricProfilePage.Cursor? = nil) async {
        guard !loading else { return }; loading = true; pageError = nil
        defer { loading = false }
        do {
            let result = try await client.evaluationProfiles(side: side, cursor: cursor)
            guard !Task.isCancelled else { return }
            guard result.items.count <= 100, Set(result.items.map(\.id)).count == result.items.count,
                  result.items.allSatisfy({ $0.side == side && UUID(uuidString: $0.id) != nil && BiometricBacktestInput.isHash($0.resolvedHash) }) else {
                throw BiometricBacktestInput.error("The candidate library returned inconsistent identities.")
            }
            if let next = result.nextCursor, next == cursor { throw BiometricBacktestInput.error("The candidate page did not advance.") }
            page = result; self.cursor = cursor
        } catch { if !Task.isCancelled { pageError = error.localizedDescription } }
    }
    func select(_ revision: BiometricProfileRevision) {
        guard fresh(), let overview, let draft else { error = "Refresh the current baseline before selecting a candidate."; return }
        do { try draft.select(revision, overview: overview) } catch { self.error = error.localizedDescription }
    }
    func prepareCurrentBaseline() async {
        guard fresh(), let selected = draft?.candidate else { return }
        do {
            let revision = try await client.evaluationProfile(id: selected.id)
            guard revision.resolvedHash == selected.hash, fresh() else { throw BiometricBacktestInput.error("The selected candidate changed or the baseline needs refresh.") }
            select(revision)
        } catch { self.error = error.localizedDescription }
    }
    func review() throws -> BiometricBacktestReview {
        guard fresh(), let draft, let overview, let candidate = draft.candidate else { throw BiometricBacktestInput.error("Select a candidate after refreshing the current baseline.") }
        let request = try draft.request(currentGeneration: overview.desired.binding.generation)
        return .init(side: side, datasetId: draft.dataset.id, datasetHash: draft.dataset.contentHash, protocolHash: experiment.protocolHash,
                     candidateHash: candidate.hash, scope: experiment.protocol.backtestScope, holdoutAcknowledged: draft.holdoutAcknowledged, request: request)
    }
}
