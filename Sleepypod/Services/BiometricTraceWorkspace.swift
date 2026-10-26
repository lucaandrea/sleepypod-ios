import Foundation
import Observation

@MainActor @Observable final class BiometricTraceWorkspace {
    enum Kind: Sendable { case stages, numeric }
    let job: BiometricBacktestJob
    let side: Side
    let kind: Kind
    let nights: [BiometricNumericReport.Night]
    let client: any BiometricReportsServing
    private(set) var selection: BiometricTraceSelection
    private(set) var stagePage: BiometricStageTracePage?
    private(set) var numericPage: BiometricNumericTracePage?
    private(set) var loading = false
    private(set) var error: String?
    private var offsets = [0]
    private var generation = 0
    init(job: BiometricBacktestJob, side: Side, hash: String, kind: Kind, nights: [BiometricNumericReport.Night], client: any BiometricReportsServing) {
        self.job = job; self.side = side; self.kind = kind; self.nights = nights; self.client = client
        selection = .init(jobId: job.id, contentHash: hash, configuration: nights.first?.evaluations.first?.label ?? .defaults, cohortId: nights.first?.cohortId ?? "")
    }
    var configurations: [BiometricReportConfiguration] { nights.first { $0.cohortId == selection.cohortId }?.evaluations.map(\.label) ?? [] }
    var canGoBack: Bool { offsets.count > 1 && !loading }
    var next: BiometricTraceCursor? { kind == .stages ? stagePage?.nextCursor : numericPage?.nextCursor }
    func chooseNight(_ id: String) async {
        guard let night = nights.first(where: { $0.cohortId == id }) else { return }
        selection.cohortId = id
        if !night.evaluations.contains(where: { $0.label == selection.configuration }) { selection.configuration = night.evaluations.first?.label ?? .defaults }
        resetPages(); await load()
    }
    func chooseConfiguration(_ configuration: BiometricReportConfiguration) async {
        guard configurations.contains(configuration) else { return }
        selection.configuration = configuration; resetPages(); await load()
    }
    func forward() async {
        guard !loading, let next, next.contentHash == selection.contentHash, next.offset > selection.offset else { return }
        offsets.append(next.offset); selection.offset = next.offset; clear(); await load()
    }
    func back() async {
        guard canGoBack else { return }
        offsets.removeLast(); selection.offset = offsets.last ?? 0; clear(); await load()
    }
    /// Every response is checked against the captured selection; older reads cannot change a new page.
    func load() async {
        guard !selection.cohortId.isEmpty, configurations.contains(selection.configuration) else { generation += 1; loading = false; clear(); return }
        generation += 1; let reading = generation, selected = selection; loading = true
        defer { if generation == reading { loading = false } }
        do {
            switch kind {
            case .stages:
                let result = try await client.stages(selected)
                try result.validate(selected, job: job)
                guard !Task.isCancelled, generation == reading, selection == selected else { return }
                stagePage = result
            case .numeric:
                let result = try await client.numeric(selected)
                try result.validate(selected, job: job, side: side)
                guard !Task.isCancelled, generation == reading, selection == selected else { return }
                numericPage = result
            }
            error = nil
        } catch { if !Task.isCancelled, generation == reading { clear(); self.error = error.localizedDescription } }
    }
    private func clear() { stagePage = nil; numericPage = nil; error = nil }
    private func resetPages() { offsets = [0]; selection.offset = 0; clear() }
}

@MainActor @Observable final class BiometricReferenceTraceWorkspace {
    let job: BiometricBacktestJob
    let side: Side
    let metric: BiometricReferenceTraceMetric
    let clockOffset: Int
    let client: any BiometricReportsServing
    private(set) var selection: BiometricTraceSelection
    private(set) var page: BiometricReferenceTracePage?
    private(set) var loading = false
    private(set) var error: String?
    private var offsets = [0]
    private var generation = 0
    init(job: BiometricBacktestJob, side: Side, selection: BiometricTraceSelection, metric: BiometricReferenceTraceMetric, clockOffset: Int, client: any BiometricReportsServing) {
        self.job = job; self.side = side; self.selection = selection; self.metric = metric; self.clockOffset = clockOffset; self.client = client
        self.selection.offset = 0
    }
    var canGoBack: Bool { offsets.count > 1 && !loading }
    func forward() async {
        guard !loading, let next = page?.nextCursor, next.contentHash == selection.contentHash, next.offset > selection.offset else { return }
        offsets.append(next.offset); selection.offset = next.offset; page = nil; await load()
    }
    func back() async {
        guard canGoBack else { return }
        offsets.removeLast(); selection.offset = offsets.last ?? 0; page = nil; await load()
    }
    func load() async {
        generation += 1; let reading = generation, selected = selection; loading = true
        defer { if generation == reading { loading = false } }
        do {
            let result = try await client.references(selected, metric: metric)
            try result.validate(selected, metric: metric, job: job, side: side, clockOffset: clockOffset)
            guard !Task.isCancelled, generation == reading, selection == selected else { return }
            page = result; error = nil
        } catch { if !Task.isCancelled, generation == reading { page = nil; self.error = error.localizedDescription } }
    }
}
