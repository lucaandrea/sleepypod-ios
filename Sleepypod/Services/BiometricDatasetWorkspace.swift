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
    private func finish(_ retained: BiometricBacktestPending, _ result: BiometricDataset) throws {
        try store.remove(retained, scope: client.scope, side: side); pending = nil; receipt = result
        if savedDataset?.id == result.id { savedDataset = result }
        let kind = result.manifest.version == "waveform-dataset-manifest-v1" ? "Waveform inputs" : "Processed inputs"
        notice = result.available ? "\(kind) retained. Saving these inputs does not run an evaluation or change a profile." : "\(kind) released; metadata and existing reports remain. These inputs cannot run a new evaluation."
    }
}
