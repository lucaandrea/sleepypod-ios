import Foundation

enum BiometricReportMetric: String, Codable, CaseIterable, Sendable {
    case heartRate = "heart_rate", breathing = "breathing_rate", variability = "window_ibi_variability_v1"
    var title: String {
        switch self {
        case .heartRate: "Heart rate"
        case .breathing: "Breathing rate"
        case .variability: "Window IBI variability index"
        }
    }
    var unit: String {
        switch self {
        case .heartRate: "bpm"
        case .breathing: "breaths/min"
        case .variability: "ms"
        }
    }
}
struct BiometricNumericMetrics: Codable, Sendable {
    let mae: Double?
    let medianAbsoluteError: Double?
    let p95AbsoluteError: Double?
    let signedBias: Double?
}
struct BiometricNumericSupport: Codable, Sendable {
    let metrics: BiometricNumericMetrics?
    let pairedCount: Int
    let referenceCoverage: Double?
}
struct BiometricNumericComparison: Codable, Sendable {
    struct Differences: Codable, Sendable {
        let commonMae: Double?
        let commonMedianAbsoluteError: Double?
        let commonP95AbsoluteError: Double?
        let commonSignedBias: Double?
        let ownMae: Double?
        let referenceCoverage: Double?
    }
    let version: String
    let metric: BiometricReportMetric
    let baseline: BiometricReportConfiguration
    let candidate: BiometricReportConfiguration
    let baselineHash: String
    let candidateHash: String
    let commonSupportScope: String
    let supportDefinition: String
    let commonObservationCount: Int
    let ownSupport: BiometricReportPair<BiometricNumericSupport>
    let commonSupport: BiometricReportPair<BiometricNumericSupport>
    let differences: Differences
    let lostObservationTimestamps: Int
    let addedObservationTimestamps: Int
    let ambiguousObservationTimestamps: BiometricReportPair<Int>
    let coverageReduced: Bool
    let interpretation: String
    var supported: Bool {
        version == "paired-numeric-support-v1" && commonSupportScope == "all_configurations"
        && supportDefinition == "identical_unambiguous_observation_timestamps"
        && interpretation == "descriptive_numeric_agreement_not_validated_improvement"
        && [commonObservationCount, lostObservationTimestamps, addedObservationTimestamps,
            ambiguousObservationTimestamps.baseline, ambiguousObservationTimestamps.candidate].allSatisfy { $0 >= 0 }
    }
}
struct BiometricNumericReport: Codable, Sendable {
    struct Score: Codable, Sendable {
        enum Status: String, Codable, Sendable {
            case compared, noReference = "no_reference", noOverlap = "no_overlap", incompatible
            var title: String {
                switch self {
                case .compared: "Compared"
                case .noReference: "No reference"
                case .noOverlap: "No overlap"
                case .incompatible: "Incompatible reference"
                }
            }
        }
        let metric: BiometricReportMetric
        let status: Status
        let metrics: BiometricNumericMetrics?
        let pairedCount: Int
        let referenceCoverage: Double?
        let outputCoverage: Double?
        let unmatchedReferences: Int
        let unmatchedObservations: Int
        let exclusions: [String: Int]
    }
    struct Window: Codable, Sendable { let startMs: Double; let endMs: Double; let observationCount: Int; let numeric: [Score] }
    struct Evaluation: Codable, Sendable { let label: BiometricReportConfiguration; let configHash: String; let windows: [Window] }
    struct ComparisonWindow: Codable, Sendable { let startMs: Double; let endMs: Double; let metrics: [BiometricNumericComparison] }
    struct Night: Codable, Sendable, Identifiable {
        let cohortId: String
        let numericComparisons: [ComparisonWindow]?
        let evaluations: [Evaluation]
        var id: String { cohortId }
    }
    struct Summary: Codable, Sendable {
        struct Pooled: Codable, Sendable { let pairedCount: Int; let mae: Double?; let signedBias: Double? }
        struct Uncertainty: Codable, Sendable {
            let statistic: String
            let status: BiometricReportUncertainty.Status
            let interval: BiometricReportInterval?
            let limitations: [String]
        }
        let version: String
        let metric: BiometricReportMetric
        let baseline: BiometricReportConfiguration
        let candidate: BiometricReportConfiguration
        let baselineHash: String
        let candidateHash: String
        let totalNights: Int
        let scoredNights: Int
        let unscoredNights: Int
        let coverageReducedNights: Int
        let improvedErrorNights: Int
        let regressedErrorNights: Int
        let unchangedErrorNights: Int
        let equalNightMeanMaeDifference: Double?
        let pooledCommonSupport: BiometricReportPair<Pooled>
        let uncertainty: Uncertainty
    }
    struct Subgroup: Codable, Sendable {
        enum Name: String, Codable, Sendable {
            case points = "reference_points", intervals = "reference_intervals", firstHalf = "window_first_half", secondHalf = "window_second_half"
            var title: String {
                switch self {
                case .points: "Reference points"
                case .intervals: "Reference intervals"
                case .firstHalf: "First half of each window"
                case .secondHalf: "Second half of each window"
                }
            }
        }
        struct Summary: Codable, Sendable {
            let metric: BiometricReportMetric
            let baseline: BiometricReportConfiguration
            let candidate: BiometricReportConfiguration
            let baselineHash: String
            let candidateHash: String
            let scoredNights: Int
            let unscoredNights: Int
            let equalNightMeanMaeDifference: Double?
        }
        let name: Name
        let version: String
        let referenceMembershipBasis: String
        let observationCoverageScope: String
        let excludedBoundaryReferenceCount: Int
        let summary: Summary
    }
    let numericSubgroupSummary: [Subgroup]?
    let numericNightSummary: [Summary]?
    let nights: [Night]

    /// Reject unsupported score semantics rather than rendering a misleading partial comparison.
    func validate(job: BiometricBacktestJob) throws {
        guard nights.count <= 60, Set(nights.map(\.cohortId)).count == nights.count,
              (numericNightSummary?.count ?? 0) <= 9, (numericSubgroupSummary?.count ?? 0) <= 36,
              (numericNightSummary ?? []).allSatisfy({ $0.version == "numeric-night-summary-v1" && job.matches($0.baseline, hash: $0.baselineHash) && job.matches($0.candidate, hash: $0.candidateHash) && $0.uncertainty.statistic == "equal_night_mean_common_mae_difference" }),
              (numericSubgroupSummary ?? []).allSatisfy({ $0.version == "reference-defined-numeric-subgroups-v1" && job.matches($0.summary.baseline, hash: $0.summary.baselineHash) && job.matches($0.summary.candidate, hash: $0.summary.candidateHash) && $0.referenceMembershipBasis == "native_reference_time" && $0.observationCoverageScope == "complete_scoring_windows" }),
              nights.allSatisfy({ night in
                  night.evaluations.count <= 3 && Set(night.evaluations.map(\.label)).count == night.evaluations.count
                  && (night.numericComparisons?.count ?? 0) <= 60
                  && (night.numericComparisons ?? []).allSatisfy { $0.metrics.count <= 9 && $0.metrics.allSatisfy { $0.supported && job.matches($0.baseline, hash: $0.baselineHash) && job.matches($0.candidate, hash: $0.candidateHash) } }
                  && night.evaluations.allSatisfy { evaluation in
                      job.matches(evaluation.label, hash: evaluation.configHash) && evaluation.windows.count <= 60 && evaluation.windows.allSatisfy { window in
                          window.startMs.isFinite && window.endMs.isFinite && window.endMs > window.startMs && window.observationCount >= 0
                          && window.numeric.count <= 3 && Set(window.numeric.map(\.metric)).count == window.numeric.count
                          && window.numeric.allSatisfy { $0.pairedCount >= 0 && $0.unmatchedReferences >= 0 && $0.unmatchedObservations >= 0 && $0.exclusions.values.allSatisfy { $0 >= 0 } }
                      }
                  }
              }) else { throw BiometricBacktestInput.error("Numerical details are unavailable or incompatible.") }
    }
}
