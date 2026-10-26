import Foundation

struct BiometricReportDescriptor: Codable, Sendable {
    let jobId: String
    let fencingToken: Int
    let report: JSONValue?
    let contentHash: String
    let completedAtMs: Double
    let releasedAtMs: Double?
    let available: Bool
    let currentHoldoutUseCount: Int
    let projection: String
    let contentHashScope: String

    /// A summary hash identifies the complete retained report, not these projected bytes.
    func validate(job: BiometricBacktestJob) throws {
        guard jobId == job.id, fencingToken > 0, BiometricBacktestInput.isHash(contentHash),
              currentHoldoutUseCount >= 0, contentHashScope == "complete_retained_report",
              ["scores_without_stage_trace_rows_v1", "scores_without_replay_trace_rows_v1"].contains(projection),
              completedAtMs.isFinite, completedAtMs >= 0,
              available ? (report != nil && report != .null && releasedAtMs == nil) : releasedAtMs != nil else {
            throw BiometricBacktestInput.error("This report descriptor does not match the selected job or supported retained format.")
        }
    }
    func decoded<Value: Decodable>(_ type: Value.Type) throws -> Value {
        guard available, let report else { throw BiometricBacktestInput.error("Detailed results have been released.") }
        return try JSONDecoder().decode(type, from: JSONEncoder().encode(report))
    }
}

enum BiometricEvidenceStatus: String, Codable, Sendable {
    case insufficient = "insufficient_evidence", improved, unchanged = "no_material_change", regressed, incompatible
    var title: String {
        switch self {
        case .insufficient: "Insufficient evidence for validated improvement"
        case .improved: "Improved agreement under the evaluation policy"
        case .unchanged: "No material improvement under the evaluation policy"
        case .regressed: "Regression under the evaluation policy"
        case .incompatible: "Incompatible evaluation evidence"
        }
    }
}

enum BiometricReportConfiguration: String, Codable, CaseIterable, Sendable {
    case defaults = "default", current, candidate
    func title(waveform: Bool) -> String {
        switch self {
        case .defaults: "System defaults"
        case .current: waveform ? "Current baseline" : "Current stage view"
        case .candidate: "Candidate"
        }
    }
}

struct BiometricReportPair<Value: Codable & Sendable>: Codable, Sendable {
    let baseline: Value
    let candidate: Value
}
struct BiometricReportInterval: Codable, Sendable { let lower: Double; let upper: Double }
struct BiometricReportUncertainty: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case notRequested = "not_requested", insufficient = "insufficient_nights", degenerate, estimated
        var title: String {
            switch self {
            case .notRequested: "Not requested"
            case .insufficient: "Insufficient paired nights"
            case .degenerate: "No estimable variation"
            case .estimated: "Exploratory interval estimated"
            }
        }
    }
    let status: Status
    let interval: BiometricReportInterval?
    let limitations: [String]
}
struct BiometricReportAssessment: Codable, Sendable {
    let policy: JSONValue?
    let baseline: BiometricReportConfiguration
    let candidate: BiometricReportConfiguration
    let status: BiometricEvidenceStatus
    let missingEvidence: [String]
    let failedThresholds: [String]
    let designated: Bool
}

struct BiometricEvaluationReport: Codable, Sendable {
    struct Calibration: Codable, Sendable { let source: String; let quality: Double }
    struct EvaluationProtocol: Codable, Sendable {
        let mode: BiometricExperimentProtocol.Mode
        let waveformStages: Bool?
        let objectivePolicy: JSONValue?
        let objectivePolicies: [JSONValue]?
        let stageObjectivePolicy: JSONValue?
    }
    struct StageSummary: Codable, Sendable {
        struct Pooled: Codable, Sendable { let agreement: Double?; let macroF1: Double?; let pairedDurationMs: Double }
        let baseline: BiometricReportConfiguration
        let candidate: BiometricReportConfiguration
        let baselineHash: String
        let candidateHash: String
        let totalNights: Int
        let scoredNights: Int
        let unscoredNights: Int
        let coverageReducedNights: Int
        let improvedAgreementNights: Int
        let regressedAgreementNights: Int
        let unchangedAgreementNights: Int
        let equalNightMeanAgreementDifference: Double?
        let pooledCommonSupport: BiometricReportPair<Pooled>
        let uncertainty: BiometricReportUncertainty
    }
    let version: String
    let status: BiometricEvidenceStatus
    let qualificationWarning: String?
    let datasetId: String
    let datasetHash: String
    let protocolHash: String
    let manifestHash: String
    let evaluatorBuildHash: String
    let side: Side
    let split: BiometricEvaluationSplit
    let evidence: String
    let holdoutUse: Int
    let `protocol`: EvaluationProtocol
    let objectiveAssessments: [BiometricReportAssessment]?
    let stageObjectiveAssessments: [BiometricReportAssessment]?
    let calibration: Calibration
    let limitations: [String]
    let stageNightSummary: [StageSummary]
    let jobOperations: JSONValue?
    let waveform: JSONValue?
    var hasWaveforms: Bool { self.protocol.mode == .waveform }
    var hasStages: Bool { self.protocol.mode == .stages || (hasWaveforms && self.protocol.waveformStages == true) }
    func validate(job: BiometricBacktestJob, side: Side, projection: String) throws {
        let expectedVersion = hasWaveforms ? "waveform-backtest-report-v1" : "processed-backtest-report-v1"
        let expectedProjection = hasWaveforms ? "scores_without_replay_trace_rows_v1" : "scores_without_stage_trace_rows_v1"
        guard version == expectedVersion, projection == expectedProjection, self.side == side, datasetId == job.datasetId,
              datasetHash == job.datasetHash, evaluatorBuildHash == job.evaluatorBuildHash, split == job.split,
              self.protocol.mode.backtestScope == job.evaluationScope,
              [datasetHash, protocolHash, manifestHash, evaluatorBuildHash].allSatisfy(BiometricBacktestInput.isHash),
              calibration.source == "explicit_assumption", calibration.quality.isFinite, (0...1).contains(calibration.quality),
              stageNightSummary.count <= 3, (objectiveAssessments?.count ?? 0) <= 6, (stageObjectiveAssessments?.count ?? 0) <= 2,
              stageNightSummary.allSatisfy({ job.matches($0.baseline, hash: $0.baselineHash) && job.matches($0.candidate, hash: $0.candidateHash)
                  && [$0.totalNights, $0.scoredNights, $0.unscoredNights, $0.coverageReducedNights, $0.improvedAgreementNights, $0.regressedAgreementNights, $0.unchangedAgreementNights].allSatisfy { $0 >= 0 } }) else {
            throw BiometricBacktestInput.error("This report version, structure or frozen job identity is unsupported.")
        }
    }
}

private extension BiometricExperimentProtocol.Mode {
    var backtestScope: BiometricBacktestJob.Scope {
        switch self {
        case .comparison: .comparison
        case .stages: .stages
        case .waveform: .waveform
        }
    }
}

/// The release endpoint returns the unprojected result descriptor, not a summary.
struct BiometricReportReleaseReceipt: Codable, Equatable, Sendable {
    let jobId: String
    let contentHash: String
    let available: Bool
    let releasedAtMs: Double?
    func confirms(id: String, hash: String) -> Bool {
        jobId == id && contentHash == hash && !available && (releasedAtMs.map { $0.isFinite && $0 >= 0 } ?? false)
    }
}

extension BiometricBacktestJob {
    func matches(_ configuration: BiometricReportConfiguration, hash: String) -> Bool {
        configurations.contains { $0.label == configuration.rawValue && $0.hash == hash }
    }
}

struct BiometricReportIdentity: Codable, Equatable, Sendable {
    let side: Side
    let job: BiometricBacktestJob
    let contentHash: String
    func validate(_ descriptor: BiometricReportDescriptor) throws {
        try descriptor.validate(job: job)
        guard descriptor.contentHash == contentHash else { throw BiometricBacktestInput.error("The reviewed report hash changed. Its release is not confirmed.") }
    }
}
