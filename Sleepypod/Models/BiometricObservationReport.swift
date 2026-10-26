import Foundation

struct BiometricObservationReport: Codable, Sendable {
    struct Coverage: Codable, Sendable { let usableCount: Int; let usableSlots: Int; let coverage: Double? }
    struct Score: Codable, Sendable {
        let status: BiometricNumericReport.Score.Status
        let metrics: BiometricNumericMetrics?
        let pairedCount: Int
        let referenceCoverage: Double?
        let validObservationCount: Int
        let unmatchedReferences: Int
        let unmatchedObservations: Int
    }
    struct Comparison: Codable, Sendable {
        let version: String
        let metric: BiometricReportMetric
        let baseline: BiometricReportConfiguration
        let candidate: BiometricReportConfiguration
        let baselineHash: String
        let candidateHash: String
        let commonSupportScope: String
        let supportDefinition: String
        let commonObservationCount: Int
        let ownSupport: BiometricReportPair<Score>
        let commonSupport: BiometricReportPair<Score>
        let differences: BiometricNumericComparison.Differences
        let lostObservationTimestamps: Int
        let addedObservationTimestamps: Int
        let ambiguousObservationTimestamps: BiometricReportPair<Int>
        let coverageReduced: Bool
        let interpretation: String
    }
    struct Metric: Codable, Sendable, Identifiable {
        let metric: BiometricReportMetric
        let windowMs: Double?
        let current: Coverage
        let candidate: Coverage
        let coverageDifference: Double?
        let issues: [String]
        let referenceExclusions: [String: Int]
        let comparison: Comparison
        var id: String { metric.rawValue }
    }
    struct Pairing: Codable, Sendable { let activeOnly: Int; let candidateOnly: Int; let unknownInputIdentity: Int }
    struct Alignment: Codable, Sendable {
        let version: String
        let pointToleranceMs: Double
        let clockOffsetMs: Double
        let offsetSource: String
    }
    enum Health: String, Codable, Sendable {
        case issues = "issues_detected", waiting, withinLimits = "within_observed_limits"
        var title: String {
            switch self {
            case .issues: "Observed issues need review"
            case .waiting: "Waiting for the observation window"
            case .withinLimits: "Within the observed limits"
            }
        }
    }
    let schema: String
    let runId: String
    let planHash: String
    let snapshotHash: String
    let reportHash: String
    let capturedAtMs: Double
    let state: BiometricObservationState
    let reason: String?
    let health: Health
    let issues: [String]
    let expectedSlots: Int
    let observedSamples: Int
    let maximumGapMs: Double
    let attemptsObserved: Int
    let alignment: Alignment
    let metrics: [Metric]
    let pairing: Pairing
    let workerReceipt: JSONValue?
    let executionPolicyHash: String?
    let contextEvidence: String
    let limitations: [String]
    let referenceSummary: ReferencePreview?
    let excludedBoundaryReferences: Int
    let interpretation: String
    func validate(run: BiometricObservationRun, reference: ReferenceImportInput? = nil) throws {
        guard schema == "biometric-shadow-report-v1", runId == run.id, planHash == run.planHash,
              [planHash, snapshotHash, reportHash].allSatisfy(BiometricBacktestInput.isHash),
              interpretation == "prospective_observation_and_reference_agreement_not_activation_authorization",
              contextEvidence == "host_observations_not_live_processor_cache_attestation",
              capturedAtMs.isFinite, capturedAtMs >= 0, maximumGapMs.isFinite, maximumGapMs >= 0,
              [expectedSlots, observedSamples, attemptsObserved, excludedBoundaryReferences, pairing.activeOnly, pairing.candidateOnly, pairing.unknownInputIdentity].allSatisfy({ $0 >= 0 }),
              alignment.version == "reference-alignment-v1", alignment.clockOffsetMs.isFinite, abs(alignment.clockOffsetMs) <= 3600000,
              (0...300000).contains(alignment.pointToleranceMs), ["fixed", "training"].contains(alignment.offsetSource),
              metrics.count <= 3, Set(metrics.map(\.metric)).count == metrics.count,
              metrics.allSatisfy({ metric in
                  let comparison = metric.comparison
                  return comparison.version == "paired-numeric-support-v1" && comparison.metric == metric.metric
                      && comparison.baseline == .current && comparison.candidate == .candidate
                      && comparison.baselineHash == run.activeConfigHash && comparison.candidateHash == run.candidateConfigHash
                      && comparison.commonSupportScope == "all_configurations" && comparison.supportDefinition == "identical_unambiguous_observation_timestamps"
                      && comparison.interpretation == "descriptive_numeric_agreement_not_validated_improvement"
                      && [metric.current, metric.candidate].allSatisfy { $0.usableCount >= 0 && $0.usableSlots >= 0 && ($0.coverage.map { (0...1).contains($0) } ?? true) }
                      && metric.referenceExclusions.values.allSatisfy { $0 >= 0 }
              }) else { throw BiometricBacktestInput.error("The observation report is incompatible or belongs to another run.") }
        if let reference {
            guard reference.side == run.side, reference.subjectId == run.subjectId, referenceSummary?.matches(reference) == true else {
                throw BiometricBacktestInput.error("The reference comparison does not match this run and input.")
            }
        } else if referenceSummary != nil { throw BiometricBacktestInput.error("An unexpected reference comparison was returned for the health report.") }
        if let workerReceipt {
            guard ["biometric-shadow-receipt-v1", "biometric-shadow-partial-receipt-v1"].contains(workerReceipt["schema"]?.string ?? ""),
                  workerReceipt["runId"] == .string(run.id), workerReceipt["planHash"] == .string(run.planHash),
                  workerReceipt["receipt"]?["memoryScope"] == .string("sum_rss_of_shadow_process_group"),
                  workerReceipt["receipt"]?["exactKernelPeak"] == .bool(false) else {
                throw BiometricBacktestInput.error("The worker receipt does not match this observation.")
            }
        }
    }
}
struct BiometricObservationReference: Sendable {
    let run: BiometricObservationRun
    let input: ReferenceImportInput
    static func parse(run: BiometricObservationRun, source: String, text: String, format: ReferenceTextParser.Format) throws -> Self {
        guard text.utf8.count <= 65536 else { throw BiometricBacktestInput.error("Reference comparison is limited to 64 KiB.") }
        let input = try ReferenceImportInput(side: run.side, subjectId: run.subjectId, source: source, rows: ReferenceTextParser.parse(text, format: format)).validated()
        let value = Self(run: run, input: input); _ = try value.body(); return value
    }
    func body() throws -> JSONValue {
        _ = try input.validated(); _ = try BiometricBacktestInput.identifier(run.id)
        guard input.side == run.side, input.subjectId == run.subjectId else { throw BiometricBacktestInput.error("Reference side and sleeper must match the observation.") }
        let reference: JSONValue = .object(["side": .string(input.side.rawValue), "subjectId": .string(input.subjectId), "source": .string(input.source), "rows": .array(input.rows), "timePolicy": .object(["disambiguation": .string("reject")])])
        let envelope: JSONValue = .object(["type": .string("readShadowReport"), "input": .object(["id": .string(run.id), "reference": reference])])
        guard try JSONEncoder().encode(envelope).count <= 65536 else { throw BiometricBacktestInput.error("The complete reference comparison request exceeds 64 KiB.") }
        return .object(["reference": reference])
    }
}
