import Foundation

enum BiometricReferenceTraceMetric: String, Codable, CaseIterable, Sendable {
    case heartRate = "heart_rate", breathing = "breathing_rate", variability = "window_ibi_variability_v1", stages = "sleep_stages"
    var title: String { ReferenceLabels.metric(rawValue) }
}
struct BiometricReferenceTracePage: Codable, Sendable {
    struct Item: Codable, Sendable {
        let recordKey: String
        let metric: String
        let value: Double?
        let stage: String?
        let unit: String
        let startMs: Double
        let endMs: Double
        let temporalKind: String
        let aggregation: String
        let windowMs: Double?
        let quality: Double?
        let scorable: Bool
        let exclusions: [String]
        let importId: String
        let importRevision: Int
        let importContentHash: String
        let source: String
        let compatibility: String?
    }
    let jobId: String
    let contentHash: String
    let datasetHash: String
    let cohortId: String
    let metric: BiometricReferenceTraceMetric
    let side: Side
    let provenance: String
    let timestampBasis: String
    let clockOffsetMs: Int
    let pointToleranceMs: Int
    let totalItems: Int
    let offset: Int
    let limit: Int
    let downsampled: Bool
    let items: [Item]
    let nextCursor: BiometricTraceCursor?
    func validate(_ selected: BiometricTraceSelection, metric: BiometricReferenceTraceMetric, job: BiometricBacktestJob, side: Side, clockOffset: Int) throws {
        try selected.validatePage(jobId: jobId, hash: contentHash, offset: offset, limit: limit, total: totalItems, count: items.count, next: nextCursor)
        guard self.metric == metric, self.side == side, datasetHash == job.datasetHash, cohortId == selected.cohortId,
              provenance == "frozen_dataset_reference", timestampBasis == "reference_source_time", !downsampled,
              clockOffsetMs == clockOffset, (0...300000).contains(pointToleranceMs), items.allSatisfy({ item in
                  (item.metric == metric.rawValue || (metric == .variability && item.metric.hasPrefix("hrv_")))
                  && ["point", "interval"].contains(item.temporalKind) && item.endMs >= item.startMs && item.importRevision > 0
              }) else { throw BiometricBacktestInput.error("The frozen reference page does not match this report, metric or timestamp policy.") }
    }
}
