import Foundation
import Observation

@MainActor @Observable final class BiometricObservationsWorkspace {
    let side: Side
    let client: any BiometricObservationsServing
    let pendingStore: BiometricObservationPendingStore
    private(set) var templates: [BiometricObservationTemplate] = []
    private(set) var templatesLoaded = false
    private(set) var templatesError: String?
    private(set) var page: BiometricObservationPage?
    private(set) var afterId: String?
    private(set) var listError: String?
    private(set) var loading = false
    private(set) var prepared: BiometricObservationPrepared?
    private(set) var pending: BiometricObservationPending?
    private(set) var savedRun: BiometricObservationRun?
    private(set) var busy = false
    private(set) var mutationError: String?
    private(set) var notice: String?
    private var unreadable = false
    private var listGeneration = 0
    init(side: Side, client: any BiometricObservationsServing, pendingStore: BiometricObservationPendingStore) {
        self.side = side; self.client = client; self.pendingStore = pendingStore
        do {
            pending = try pendingStore.read(scope: client.scope, side: side)
            if case .create(let request) = pending { prepared = request.prepared }
        } catch { unreadable = true; mutationError = "Cannot read the retained observation request. \(error.localizedDescription)" }
    }
    var hasPending: Bool { pending != nil || unreadable }
    var canEdit: Bool { !busy && !hasPending }
    func loadTemplates() async {
        do {
            let response = try await client.templates()
            guard !Task.isCancelled else { return }
            guard response.items.count <= 8, Set(response.items.map(\.id)).count == response.items.count,
                  response.items.allSatisfy({ !$0.id.isEmpty && !$0.label.isEmpty && (1...604800000).contains($0.maximumWindowMs) }) else {
                throw BiometricBacktestInput.error("The installed observation templates are incompatible.")
            }
            templates = response.items; templatesLoaded = true; templatesError = nil
        } catch { if !Task.isCancelled { templatesError = error.localizedDescription } }
    }
    func loadList(afterId: String? = nil) async {
        if loading, self.afterId == afterId { return }
        listGeneration += 1; let generation = listGeneration
        if self.afterId != afterId { page = nil }
        self.afterId = afterId; loading = true
        defer { if generation == listGeneration { loading = false } }
        do {
            let value = try await client.list(side: side, afterId: afterId)
            guard !Task.isCancelled, generation == listGeneration else { return }
            guard value.items.count <= 20, Set(value.items.map(\.id)).count == value.items.count else { throw BiometricBacktestInput.error("The observation page is incompatible.") }
            for item in value.items { try item.validate(side: side) }
            if let next = value.nextCursor { _ = try BiometricBacktestInput.identifier(next) }
            page = value; listError = nil
        } catch { if !Task.isCancelled, generation == listGeneration { listError = error.localizedDescription } }
    }
    func invalidatePlan() { guard canEdit else { return }; prepared = nil; savedRun = nil; mutationError = nil; notice = nil }
    func prepare(_ input: BiometricObservationPreparation) async {
        guard canEdit, input.side == side else { return }
        busy = true; prepared = nil; mutationError = nil; notice = nil
        defer { busy = false }
        do {
            guard templatesError == nil, let template = templates.first(where: { $0.id == input.templateId }) else { throw BiometricBacktestInput.error("Reload and select an installed observation template.") }
            try input.validate(maximumWindowMs: template.maximumWindowMs)
            let value = try await client.prepare(input)
            try value.validate(for: input)
            guard !Task.isCancelled else { return }
            prepared = value
        } catch { if !Task.isCancelled { mutationError = error.localizedDescription } }
    }
    func schedule() async {
        guard canEdit, let prepared, savedRun == nil else { return }
        await retainAndSend(.create(.init(prepared: prepared, idempotencyKey: UUID().uuidString)))
    }
    func stop(_ run: BiometricObservationRun) async {
        guard canEdit, run.side == side, run.state.isActive else { return }
        await retainAndSend(.stop(run))
    }
    func retry() async { guard !busy, !unreadable, let pending else { return }; await send(pending) }
    /// Discarding local recovery never reverses a saved schedule or confirms worker cleanup.
    func discardRetry() async {
        guard !busy else { return }
        do {
            if let pending { try pendingStore.remove(pending, scope: client.scope, side: side) }
            else if unreadable { try pendingStore.discardUnreadable(scope: client.scope, side: side) }
            pending = nil; unreadable = false; prepared = nil; mutationError = nil
            notice = "Retry removed. Review current runs; this does not stop an observation."
            await loadList()
        } catch { mutationError = error.localizedDescription }
    }
    private func retainAndSend(_ request: BiometricObservationPending) async {
        do { try pendingStore.write(request, scope: client.scope, side: side); pending = request }
        catch { mutationError = "The request could not be retained, so it was not sent. \(error.localizedDescription)"; return }
        await send(request)
    }
    private func send(_ request: BiometricObservationPending) async {
        busy = true; mutationError = nil; notice = nil
        defer { busy = false }
        do {
            guard try pendingStore.read(scope: client.scope, side: side) == request else { throw BiometricBacktestInput.error("The retained request changed in another workspace. Reopen observations.") }
            switch request {
            case .create(let input):
                let receipt = try await client.create(input)
                try receipt.validate(side: side)
                guard input.prepared.matches(receipt) else { throw BiometricBacktestInput.error("The scheduling receipt does not match the reviewed plan.") }
                savedRun = receipt; notice = "Observation request saved. Inspect its current status; execution is not implied."
            case .stop(let selected):
                let current = try await client.get(id: selected.id)
                try current.validate(matching: selected)
                if current.state.isActive {
                    let receipt = try await client.stop(id: selected.id)
                    try receipt.run.validate(matching: selected)
                    guard !receipt.run.state.isActive else { throw BiometricBacktestInput.error("The stop outcome is not confirmed.") }
                    savedRun = receipt.run
                    notice = receipt.localAttemptSettled ? "Stop recorded; the locally owned attempt has settled. Other processes are reported separately." : "Stop recorded. Local worker cleanup has not been confirmed."
                } else {
                    savedRun = current; notice = "This run is no longer active. Saved observations remain; local worker cleanup was not confirmed by this read."
                }
            }
            try pendingStore.remove(request, scope: client.scope, side: side)
            pending = nil; prepared = nil
            await loadList(afterId: afterId)
        } catch { mutationError = "The result is not confirmed. The exact request is retained. \(error.localizedDescription)" }
    }
}

@MainActor @Observable final class BiometricObservationDetailsWorkspace {
    let initial: BiometricObservationRun
    let client: any BiometricObservationsServing
    private(set) var run: BiometricObservationRun
    private(set) var error: String?
    private(set) var reading = false
    private(set) var report: BiometricObservationReport?
    private(set) var reportError: String?
    private(set) var loadingReport = false
    private(set) var comparison: BiometricObservationReport?
    private(set) var comparisonError: String?
    private(set) var comparing = false
    private var comparisonGeneration = 0
    private var readGeneration = 0
    init(run: BiometricObservationRun, client: any BiometricObservationsServing) { initial = run; self.run = run; self.client = client }
    func refresh() async {
        guard !reading else { return }; reading = true; readGeneration += 1; let generation = readGeneration
        defer { reading = false }
        do {
            let value = try await client.get(id: initial.id)
            try value.validate(matching: initial)
            guard !Task.isCancelled, generation == readGeneration else { return }; run = value; error = nil
        } catch { if !Task.isCancelled, generation == readGeneration { self.error = error.localizedDescription } }
    }
    func accept(_ receipt: BiometricObservationRun) {
        guard (try? receipt.validate(matching: initial)) != nil else { return }
        readGeneration += 1; run = receipt; error = nil
    }
    func loadReport() async {
        guard !loadingReport else { return }; loadingReport = true; defer { loadingReport = false }
        do {
            let value = try await client.report(id: initial.id); try value.validate(run: initial)
            guard !Task.isCancelled else { return }; report = value; reportError = nil
        } catch { if !Task.isCancelled { reportError = error.localizedDescription } }
    }
    func clearComparison() { comparisonGeneration += 1; comparison = nil; comparisonError = nil; comparing = false }
    func compare(source: String, text: String, format: ReferenceTextParser.Format) async {
        clearComparison(); let generation = comparisonGeneration; comparing = true
        defer { if generation == comparisonGeneration { comparing = false } }
        do {
            let request = try BiometricObservationReference.parse(run: initial, source: source, text: text, format: format)
            let value = try await client.compare(request); try value.validate(run: initial, reference: request.input)
            guard !Task.isCancelled, generation == comparisonGeneration else { return }; comparison = value
        } catch { if !Task.isCancelled, generation == comparisonGeneration { comparisonError = error.localizedDescription } }
    }
}
