import Foundation

struct BiometricTraceCursor: Codable, Equatable, Sendable { let offset: Int; let contentHash: String }
struct BiometricTraceSelection: Equatable, Sendable {
    let jobId: String
    let contentHash: String
    var configuration: BiometricReportConfiguration = .candidate
    var cohortId: String
    var offset = 0
    var limit = 200
    func query(includeConfiguration: Bool = true) throws -> [String: String] {
        _ = try BiometricBacktestInput.identifier(jobId)
        guard BiometricBacktestInput.isHash(contentHash), (1...200).contains(cohortId.utf16.count),
              (0...1000000).contains(offset), (1...500).contains(limit) else { throw BiometricBacktestInput.error("Select a retained report, night and supported trace page.") }
        var result = ["expectedContentHash": contentHash, "cohortId": cohortId, "offset": String(offset), "limit": String(limit)]
        if includeConfiguration { result["configuration"] = configuration.rawValue }
        return result
    }
    func validatePage(jobId: String, hash: String, offset: Int, limit: Int, total: Int, count: Int, next: BiometricTraceCursor?) throws {
        let cursorMatches = next.map { $0.contentHash == hash && $0.offset == offset + count && count > 0 && offset + count < total } ?? (offset + count == total)
        guard self.jobId == jobId, contentHash == hash, self.offset == offset, self.limit == limit,
              total >= 0, offset <= total, count <= limit, offset + count <= total,
              cursorMatches else {
            throw BiometricBacktestInput.error("The trace page changed identity or did not advance. Reload this report.")
        }
    }
}
struct BiometricStageTracePage: Codable, Sendable {
    struct Item: Codable, Sendable {
        let cohortId: String
        let configurationHash: String
        let revisionId: String?
        let windowStartMs: Double
        let windowEndMs: Double
        let startMs: Double
        let endMs: Double
        let stage: BiometricReportStage
    }
    let jobId: String
    let contentHash: String
    let configuration: BiometricReportConfiguration
    let provenance: String
    let timestampBasis: String
    let clockOffsetMs: Int
    let totalItems: Int
    let offset: Int
    let limit: Int
    let downsampled: Bool
    let items: [Item]
    let nextCursor: BiometricTraceCursor?
    func validate(_ selected: BiometricTraceSelection, job: BiometricBacktestJob) throws {
        try selected.validatePage(jobId: jobId, hash: contentHash, offset: offset, limit: limit, total: totalItems, count: items.count, next: nextCursor)
        let config = job.configurations.first { $0.label == selected.configuration.rawValue }
        guard configuration == selected.configuration, provenance == "versioned_stage_replay", !downsampled,
              timestampBasis == "original_trace_before_reference_clock_offset", (-3600000...3600000).contains(clockOffsetMs), config != nil,
              items.allSatisfy({ $0.cohortId == selected.cohortId && $0.configurationHash == config?.hash && $0.revisionId == config?.revisionId
                  && $0.startMs >= $0.windowStartMs && $0.endMs <= $0.windowEndMs && $0.endMs > $0.startMs }) else {
            throw BiometricBacktestInput.error("The stage trace has incompatible source or configuration information.")
        }
    }
}
struct BiometricNumericTracePage: Codable, Sendable {
    struct Item: Codable, Sendable {
        let timestampMs: Double
        let heartRate: Double?
        let breathingRate: Double?
        let hrvIndex: Double?
        let hrvMetric: String
        let qualityScore: Double
        let flags: [String]?
        let sourceSide: Side
        let configHash: String
        let side: Side
        let limitations: [String]
        let cohortId: String
        let revisionId: String?
        func value(_ metric: BiometricReportMetric) -> Double? {
            switch metric {
            case .heartRate: heartRate
            case .breathing: breathingRate
            case .variability: hrvIndex
            }
        }
    }
    let jobId: String
    let contentHash: String
    let configuration: BiometricReportConfiguration
    let side: Side
    let provenance: String
    let timestampBasis: String
    let clockOffsetMs: Int
    let totalItems: Int
    let offset: Int
    let limit: Int
    let downsampled: Bool
    let items: [Item]
    let nextCursor: BiometricTraceCursor?
    func validate(_ selected: BiometricTraceSelection, job: BiometricBacktestJob, side: Side) throws {
        try selected.validatePage(jobId: jobId, hash: contentHash, offset: offset, limit: limit, total: totalItems, count: items.count, next: nextCursor)
        let config = job.configurations.first { $0.label == selected.configuration.rawValue }
        guard configuration == selected.configuration, self.side == side, provenance == "retained_waveform_recomputation", !downsampled,
              timestampBasis == "original_trace_before_reference_clock_offset", (-3600000...3600000).contains(clockOffsetMs), config != nil,
              items.allSatisfy({ $0.cohortId == selected.cohortId && $0.side == side && $0.configHash == config?.hash && $0.revisionId == config?.revisionId
                  && $0.hrvMetric == "window_ibi_variability_v1" && $0.qualityScore.isFinite }) else {
            throw BiometricBacktestInput.error("The numeric trace has incompatible side, source or configuration information.")
        }
    }
}
