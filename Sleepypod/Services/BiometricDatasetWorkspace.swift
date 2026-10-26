import Foundation
import Observation

@MainActor @Observable final class BiometricDatasetDraft {
    let side: Side
    var subjectId = "" { didSet { if oldValue != subjectId { selectedReferences = [:] } } }
    private(set) var selectedSessions: [Int: ReplaySessionCapabilities] = [:]
    private(set) var selectedReferences: [String: ReferenceDescriptor] = [:]
    init(side: Side) { self.side = side }
    var selection: BiometricDatasetSelection {
        .init(side: side, subjectId: subjectId.trimmingCharacters(in: .whitespacesAndNewlines), sessionIds: selectedSessions.keys.sorted(), referenceImportIds: selectedReferences.keys.sorted())
    }
    var valid: Bool { (try? selection.validated()) != nil }
    func include(_ capabilities: ReplaySessionCapabilities) throws {
        guard capabilities.session.side == side, capabilities.session.id > 0, capabilities.comparison,
              selectedSessions.count < 60 || selectedSessions[capabilities.session.id] != nil else {
            throw BiometricBacktestInput.error("Inspect an available session from this side. At most 60 sessions can be selected.")
        }
        selectedSessions[capabilities.session.id] = capabilities
    }
    func removeSession(_ id: Int) { selectedSessions[id] = nil }
    func referenceReason(_ reference: ReferenceDescriptor) -> String? {
        if !reference.available || reference.summary.side != side || reference.summary.subjectId != selection.subjectId { return "Unavailable or belongs to a different sleeper." }
        if selectedReferences.values.contains(where: { $0.familyId == reference.familyId && $0.id != reference.id }) { return "Another revision from this reference family is selected." }
        if selectedReferences.count >= 20 && selectedReferences[reference.id] == nil { return "Up to 20 reference revisions can be selected." }
        return nil
    }
    func include(_ reference: ReferenceDescriptor) throws {
        if let reason = referenceReason(reference) { throw BiometricBacktestInput.error(reason) }
        selectedReferences[reference.id] = reference
    }
    func removeReference(_ id: String) { selectedReferences[id] = nil }
}

@MainActor @Observable final class BiometricDatasetWorkspace {
    let side: Side
    let client: any BiometricDatasetsServing
    private let store: BiometricBacktestPendingStore
    private(set) var pending: BiometricBacktestPending?
    private(set) var unreadable = false
    private(set) var busy = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var receipt: BiometricDataset?
    private(set) var savedDataset: BiometricDataset?
    private(set) var savedJob: BiometricBacktestJob?
    private(set) var savedJobRequest: BiometricBacktestSubmission?
    private(set) var jobReceipt: BiometricBacktestJob?
    private(set) var reportReceipt: BiometricReportReleaseReceipt?
    private(set) var savedExperiment: BiometricExperiment?
    private(set) var savedExperimentRequest: BiometricExperimentRequest?
    private(set) var savedWaveformRequest: WaveformDatasetRequest?
    private(set) var savedSelection: BiometricDatasetSelection?
    private(set) var page: BiometricDatasetPage?
    private(set) var cursor: BiometricDatasetPage.Cursor?
    private(set) var loading = false
    private(set) var loadError: String?
    var canMutate: Bool { !busy && pending == nil && !unreadable }
    init(side: Side, client: any BiometricDatasetsServing, store: BiometricBacktestPendingStore) {
        self.side = side; self.client = client; self.store = store
        do { pending = try store.read(scope: client.scope, side: side) }
        catch { unreadable = true; self.error = "A retained backtest request cannot be read. New writes are paused. Discarding the local request does not undo a controller change." }
    }
    func load(_ cursor: BiometricDatasetPage.Cursor? = nil) async {
        guard !loading else { return }; loading = true; loadError = nil
        defer { loading = false }
        do {
            let result = try await client.datasets(side: side, cursor: cursor)
            guard !Task.isCancelled else { return }
            guard result.items.allSatisfy({ $0.side == side && $0.validIdentity }) else { throw BiometricBacktestInput.error("The dataset library returned unexpected identities. Reload before continuing.") }
            page = result; self.cursor = cursor
        } catch { if !Task.isCancelled { loadError = error.localizedDescription } }
    }
    func create(_ selection: BiometricDatasetSelection) async {
        guard canMutate, savedSelection != selection else { return }
        await performNew(.dataset(.init(selection: selection)))
    }
    func retainWaveforms(_ request: WaveformDatasetRequest, side: Side) async {
        guard canMutate else { return }
        await performNew(.waveform(side: side, request: request))
    }
    func submitJob(_ review: BiometricBacktestReview) async {
        guard canMutate, savedJobRequest != review.request else { return }
        busy = true; error = nil; notice = nil
        defer { busy = false }
        do {
            _ = try review.request.validated()
            guard review.side == side, review.request.split != .holdout || review.holdoutAcknowledged else { throw BiometricBacktestInput.error("Acknowledge this exact holdout selection before queueing.") }
            let experiment = try await client.experiment(id: review.request.experimentId)
            let inputs = try await client.dataset(id: review.datasetId)
            let candidate = try await client.evaluationProfile(id: review.request.candidateRevisionId)
            let overview = try await client.evaluationOverview(side: side)
            guard experiment.validIdentity, experiment.id == review.request.experimentId, experiment.side == side,
                  experiment.datasetId == inputs.id, experiment.protocolHash == review.protocolHash, experiment.protocol.backtestScope == review.scope,
                  inputs.validIdentity, inputs.id == review.datasetId, inputs.side == side, inputs.available, inputs.manifest.supported, inputs.contentHash == review.datasetHash,
                  inputs.manifest.splitProtocol.assignments.contains(where: { $0.split == review.request.split.rawValue }),
                  candidate.id == review.request.candidateRevisionId, candidate.side == side, candidate.resolvedHash == review.candidateHash,
                  overview.desired.binding.side == side, overview.desired.binding.generation == review.request.expectedBindingGeneration else {
                throw BiometricBacktestInput.error("The reviewed inputs, candidate or baseline changed. Return to preparation and review a new request.")
            }
            let retained = BiometricBacktestPending.submitJob(review)
            try store.write(retained, scope: client.scope, side: side); pending = retained
            try await send(retained)
        } catch { self.error = error.localizedDescription }
    }
    func cancelJob(_ job: BiometricBacktestJob) async {
        guard canMutate, job.validIdentity, job.state.cancellable else { return }
        await performNew(.cancelJob(.init(side: side, job: job)))
    }
    func inspectCancellation() async {
        guard !busy, case .cancelJob(let identity) = pending else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let retained = BiometricBacktestPending.cancelJob(identity)
            try requireCurrent(retained)
            let current = try await client.job(id: identity.id)
            guard identity.matches(current) else { throw BiometricBacktestInput.error("The cancellation receipt belongs to different job inputs.") }
            if current.state.terminal || current.state == .cancellationRequested { try finishCancellation(retained, current) }
            else { notice = "Cancellation is not confirmed. You can retry this exact job request." }
        } catch { self.error = error.localizedDescription }
    }
    func releaseReport(job: BiometricBacktestJob, descriptor: BiometricReportDescriptor) async {
        guard canMutate, job.state == .succeeded, descriptor.available else { return }
        do {
            try descriptor.validate(job: job)
            let report = try descriptor.decoded(BiometricEvaluationReport.self)
            try report.validate(job: job, side: side, projection: descriptor.projection)
            await performNew(.releaseReport(.init(side: side, job: job, contentHash: descriptor.contentHash)))
        } catch { self.error = error.localizedDescription }
    }
    func inspectReportRelease() async {
        guard !busy, case .releaseReport(let identity) = pending else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let retained = BiometricBacktestPending.releaseReport(identity)
            try requireCurrent(retained)
            guard let result = try await client.reportClient.summary(id: identity.job.id) else { throw BiometricBacktestInput.error("No report receipt is available. Release remains unconfirmed.") }
            try identity.validate(result)
            if !result.available {
                try finishReportRelease(retained, .init(jobId: result.jobId, contentHash: result.contentHash, available: result.available, releasedAtMs: result.releasedAtMs))
            } else { notice = "Detailed results remain retained. You can retry this exact report release." }
        } catch { self.error = error.localizedDescription }
    }
    func createExperiment(_ request: BiometricExperimentRequest, parent: BiometricDataset) async {
        guard canMutate, savedExperimentRequest != request else { return }
        busy = true; error = nil; notice = nil
        defer { busy = false }
        do {
            guard parent.side == side, request.datasetId == parent.id else { throw BiometricBacktestInput.error("The reviewed inputs belong to another dataset or side.") }
            _ = try request.validated()
            try request.protocol.validateEditorProtocol(for: parent)
            let identity = BiometricBacktestPending.DatasetIdentity(id: parent.id, contentHash: parent.contentHash, side: side)
            let current = try await client.dataset(id: parent.id)
            guard identity.matches(current) else { throw BiometricBacktestInput.error("The frozen input identity changed. Review it again before saving.") }
            try request.protocol.validateEditorProtocol(for: current)
            let retained = BiometricBacktestPending.experiment(parent: identity, request: request)
            try store.write(retained, scope: client.scope, side: side); pending = retained
            try await send(retained)
        } catch { self.error = error.localizedDescription }
    }
    func release(_ dataset: BiometricDataset) async {
        guard canMutate, dataset.available else { return }
        await performNew(.releaseDataset(.init(id: dataset.id, contentHash: dataset.contentHash, side: dataset.side)))
    }
    /// The server pins creation to the retained key; explicit retry never substitutes a fresh request.
    func retry() async {
        guard !busy, let pending else { return }
        busy = true; error = nil; notice = nil
        defer { busy = false }
        do { try await send(pending) } catch { self.error = error.localizedDescription }
        await load()
    }
    func inspectRelease() async {
        guard !busy, case .releaseDataset(let identity) = pending else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let retained = BiometricBacktestPending.releaseDataset(identity)
            try requireCurrent(retained)
            let result = try await client.dataset(id: identity.id)
            guard identity.matches(result) else { throw BiometricBacktestInput.error("The retained dataset identity does not match this release.") }
            if !result.available, result.releasedAtMs != nil { try finish(retained, result) }
            else { notice = "Inputs are still retained. You can retry the exact release request." }
        } catch { self.error = error.localizedDescription }
    }
    func discardPending() {
        guard !busy else { return }
        do {
            if let pending { try store.remove(pending, scope: client.scope, side: side) }
            else if unreadable { try store.discardUnreadable(scope: client.scope, side: side) }
            pending = nil; unreadable = false; error = nil
            notice = "Local request removed. Any controller change remains. Reload retained datasets before starting again."
        } catch { self.error = error.localizedDescription }
    }
    private func performNew(_ retained: BiometricBacktestPending) async {
        guard retained.side == side else { error = "This request belongs to another side."; return }
        busy = true; error = nil; receipt = nil; notice = nil
        defer { busy = false }
        do {
            if case .dataset(let request) = retained { _ = try request.validated() }
            if case .waveform(_, let request) = retained { _ = try request.validated() }
            try store.write(retained, scope: client.scope, side: side); pending = retained
            try await send(retained)
        } catch { self.error = error.localizedDescription }
        await load()
    }
    private func requireCurrent(_ expected: BiometricBacktestPending) throws {
        guard try store.read(scope: client.scope, side: side) == expected else { throw BiometricBacktestInput.error("This request was removed or replaced in another workspace. Reopen Backtests before continuing.") }
    }
    private func send(_ retained: BiometricBacktestPending) async throws {
        try requireCurrent(retained)
        switch retained {
        case .releaseReport(let identity):
            guard let current = try await client.reportClient.summary(id: identity.job.id) else { throw BiometricBacktestInput.error("No report receipt is available. Release remains unconfirmed.") }
            try identity.validate(current)
            if !current.available {
                try finishReportRelease(retained, .init(jobId: current.jobId, contentHash: current.contentHash, available: current.available, releasedAtMs: current.releasedAtMs)); return
            }
            try requireCurrent(retained)
            guard let result = try await client.reportClient.release(id: identity.job.id, expectedHash: identity.contentHash) else { throw BiometricBacktestInput.error("The controller did not confirm report release. Keep the exact request for recovery.") }
            try finishReportRelease(retained, result)
        case .submitJob(let review):
            let result = try await client.submit(review.request)
            guard review.matches(result) else { throw BiometricBacktestInput.error("The queued job does not match the reviewed inputs and candidate. Keep the request for recovery.") }
            try store.remove(retained, scope: client.scope, side: side); pending = nil
            savedJob = result; savedJobRequest = review.request; jobReceipt = result
            notice = "Evaluation request saved. Current state: \(result.state.title). A saved request does not establish execution or improvement."
        case .cancelJob(let identity):
            let current = try await client.job(id: identity.id)
            guard identity.matches(current) else { throw BiometricBacktestInput.error("The selected job inputs changed. Review the job before cancelling.") }
            if current.state.terminal || current.state == .cancellationRequested { try finishCancellation(retained, current); return }
            try requireCurrent(retained)
            let experiment = try await client.experiment(id: identity.experimentId)
            guard experiment.side == side, experiment.id == identity.experimentId, experiment.datasetId == identity.datasetId else { throw BiometricBacktestInput.error("This job belongs to another bed side.") }
            try requireCurrent(retained)
            let result = try await client.cancelJob(id: identity.id)
            guard identity.matches(result), result.state.terminal || result.state == .cancellationRequested else { throw BiometricBacktestInput.error("Cancellation has not been confirmed. Keep the request for recovery.") }
            try finishCancellation(retained, result)
        case .experiment(let parent, let request):
            guard parent.side == side, parent.id == request.datasetId else { throw BiometricBacktestInput.error("The retained experiment does not match its reviewed inputs.") }
            let result = try await client.create(request)
            guard request.matches(result, side: side) else { throw BiometricBacktestInput.error("The experiment response does not match the frozen protocol. Keep this request for recovery.") }
            try store.remove(retained, scope: client.scope, side: side); pending = nil
            savedExperiment = result; savedExperimentRequest = request
            notice = "Evaluation protocol saved. No evaluation has run and the active profile has not changed."
        case .dataset(let request):
            let result = try await client.create(request)
            guard request.matches(result) else { throw BiometricBacktestInput.error("The saved dataset does not match the retained selection. Keep the request for recovery.") }
            try finish(retained, result); savedSelection = request.selection; savedDataset = result
        case .waveform(let side, let request):
            let result = try await client.createWaveform(request)
            if result.status == .deferred {
                guard result.dataset == nil else { throw WaveformInput.failure("A deferred response cannot confirm retained inputs. Keep this request for recovery.") }
                notice = "Waveform retention was deferred. Your exact selection and retry key are saved. Retry when resources are available."
                return
            }
            guard let dataset = result.dataset, request.matches(dataset, side: side) else {
                throw WaveformInput.failure("The waveform receipt does not match the retained parent and selection. Keep the request for recovery.")
            }
            try finish(retained, dataset); savedWaveformRequest = request
        case .releaseDataset(let identity):
            let current = try await client.dataset(id: identity.id)
            guard identity.matches(current) else { throw BiometricBacktestInput.error("The dataset identity changed. Review it again before release.") }
            if !current.available, current.releasedAtMs != nil { try finish(retained, current); return }
            try requireCurrent(retained)
            let result = try await client.release(id: identity.id)
            guard identity.matches(result), !result.available, result.releasedAtMs != nil else { throw BiometricBacktestInput.error("The release has not been confirmed. Keep the retained request for recovery.") }
            try finish(retained, result)
        }
    }
    private func finishReportRelease(_ retained: BiometricBacktestPending, _ result: BiometricReportReleaseReceipt) throws {
        guard case .releaseReport(let identity) = retained, result.confirms(id: identity.job.id, hash: identity.contentHash) else {
            throw BiometricBacktestInput.error("The detailed report release has not been confirmed. Keep the exact request for recovery.")
        }
        try store.remove(retained, scope: client.scope, side: side); pending = nil; reportReceipt = result
        notice = "Detailed results released. The report hash, job history and holdout exposure audit remain."
    }
    private func finishCancellation(_ retained: BiometricBacktestPending, _ result: BiometricBacktestJob) throws {
        try store.remove(retained, scope: client.scope, side: side); pending = nil; jobReceipt = result
        switch result.state {
        case .cancelled: notice = "Evaluation cancelled. Its history and any holdout exposure remain."
        case .cancellationRequested: notice = "Cancellation requested. The worker has not yet confirmed that it stopped."
        default: notice = "The job has already finished with state: \(result.state.title). Cancellation did not change that result."
        }
    }
    private func finish(_ retained: BiometricBacktestPending, _ result: BiometricDataset) throws {
        try store.remove(retained, scope: client.scope, side: side); pending = nil; receipt = result
        if savedDataset?.id == result.id { savedDataset = result }
        let kind = result.manifest.version == "waveform-dataset-manifest-v1" ? "Waveform inputs" : "Processed inputs"
        notice = result.available ? "\(kind) retained. Saving these inputs does not run an evaluation or change a profile." : "\(kind) released; metadata and existing reports remain. These inputs cannot run a new evaluation."
    }
}
