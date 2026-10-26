import Foundation

struct BiometricReportExample: Decodable, Sendable, Identifiable {
    let name: String
    let job: BiometricBacktestJob
    let summary: BiometricReportDescriptor
    let stagePages: [BiometricStageTracePage]
    let numericPages: [BiometricNumericTracePage]
    let referencePages: [BiometricReferenceTracePage]
    var id: String { job.id }
    var title: String { job.evaluationScope.title }
    static func load() throws -> [Self] {
        guard let url = Bundle.main.url(forResource: "backtest-reports-demo", withExtension: "json") else { throw BiometricBacktestInput.error("The bundled report examples are unavailable.") }
        return try JSONDecoder().decode([Self].self, from: Data(contentsOf: url))
    }
}

/// Precomputed Core examples only. Never attach example scores to a newly queued candidate.
actor DemoBiometricReportsClient: BiometricReportsServing {
    private var released: [String: Double] = [:]
    private var cachedExamples: [BiometricReportExample]?
    func summary(id: String) async throws -> BiometricReportDescriptor? {
        guard let example = try examples().first(where: { $0.id == id }) else { return nil }
        let saved = example.summary
        guard let time = released[id] else { return saved }
        return .init(jobId: saved.jobId, fencingToken: saved.fencingToken, report: nil, contentHash: saved.contentHash,
                     completedAtMs: saved.completedAtMs, releasedAtMs: time, available: false, currentHoldoutUseCount: saved.currentHoldoutUseCount,
                     projection: "scores_without_stage_trace_rows_v1", contentHashScope: "complete_retained_report")
    }
    func release(id: String, expectedHash: String) async throws -> BiometricReportReleaseReceipt? {
        let example = try retainedExample(id: id, hash: expectedHash, allowReleased: true)
        let time = released[id] ?? (Date.now.timeIntervalSince1970 * 1000).rounded(.down); released[id] = time
        return .init(jobId: id, contentHash: example.summary.contentHash, available: false, releasedAtMs: time)
    }
    func stages(_ selection: BiometricTraceSelection) async throws -> BiometricStageTracePage {
        let example = try retainedExample(id: selection.jobId, hash: selection.contentHash, cohort: selection.cohortId)
        let pages = example.stagePages.filter { $0.configuration == selection.configuration }
        guard let first = pages.first else { throw BiometricBacktestInput.error("This example has no stage replay.") }
        let all = pages.flatMap(\.items).filter { $0.cohortId == selection.cohortId }
        let selected = try page(all, selection)
        return .init(jobId: selection.jobId, contentHash: selection.contentHash, configuration: selection.configuration,
                     provenance: first.provenance, timestampBasis: first.timestampBasis, clockOffsetMs: first.clockOffsetMs,
                     totalItems: all.count, offset: selection.offset, limit: selection.limit, downsampled: false, items: selected.items, nextCursor: selected.next)
    }
    func numeric(_ selection: BiometricTraceSelection) async throws -> BiometricNumericTracePage {
        let example = try retainedExample(id: selection.jobId, hash: selection.contentHash, cohort: selection.cohortId)
        let pages = example.numericPages.filter { $0.configuration == selection.configuration }
        guard let first = pages.first else { throw BiometricBacktestInput.error("This example has no recomputed waveform readings.") }
        let all = pages.flatMap(\.items).filter { $0.cohortId == selection.cohortId }
        let selected = try page(all, selection)
        return .init(jobId: selection.jobId, contentHash: selection.contentHash, configuration: selection.configuration, side: first.side,
                     provenance: first.provenance, timestampBasis: first.timestampBasis, clockOffsetMs: first.clockOffsetMs,
                     totalItems: all.count, offset: selection.offset, limit: selection.limit, downsampled: false, items: selected.items, nextCursor: selected.next)
    }
    func references(_ selection: BiometricTraceSelection, metric: BiometricReferenceTraceMetric) async throws -> BiometricReferenceTracePage {
        let example = try retainedExample(id: selection.jobId, hash: selection.contentHash, cohort: selection.cohortId)
        let pages = example.referencePages.filter { $0.metric == metric && $0.cohortId == selection.cohortId }
        guard let first = pages.first else { throw BiometricBacktestInput.error("The selected example night is unavailable.") }
        let all = pages.flatMap(\.items), selected = try page(all, selection)
        return .init(jobId: selection.jobId, contentHash: selection.contentHash, datasetHash: first.datasetHash,
                     cohortId: selection.cohortId, metric: metric, side: first.side, provenance: first.provenance, timestampBasis: first.timestampBasis,
                     clockOffsetMs: first.clockOffsetMs, pointToleranceMs: first.pointToleranceMs, totalItems: all.count,
                     offset: selection.offset, limit: selection.limit, downsampled: false, items: selected.items, nextCursor: selected.next)
    }
    private func retainedExample(id: String, hash: String, allowReleased: Bool = false, cohort: String? = nil) throws -> BiometricReportExample {
        guard let example = try examples().first(where: { $0.id == id }), example.summary.contentHash == hash else {
            throw BiometricBacktestInput.error("The example report identity changed.")
        }
        guard allowReleased || released[id] == nil else { throw BiometricBacktestInput.error("Detailed example results have been released.") }
        if let cohort {
            let numeric = try example.summary.decoded(BiometricNumericReport.self)
            guard numeric.nights.contains(where: { $0.cohortId == cohort }) else { throw BiometricBacktestInput.error("The selected example night is unavailable.") }
        }
        return example
    }
    private func examples() throws -> [BiometricReportExample] {
        if let cachedExamples { return cachedExamples }
        let loaded = try BiometricReportExample.load(); cachedExamples = loaded; return loaded
    }
    private func page<Value>(_ items: [Value], _ selection: BiometricTraceSelection) throws -> (items: [Value], next: BiometricTraceCursor?) {
        _ = try selection.query()
        guard selection.offset <= items.count else { throw BiometricBacktestInput.error("The trace cursor exceeds the selected example.") }
        let values = Array(items.dropFirst(selection.offset).prefix(selection.limit)), next = selection.offset + min(selection.limit, items.count - selection.offset)
        return (values, next < items.count ? .init(offset: next, contentHash: selection.contentHash) : nil)
    }
}
