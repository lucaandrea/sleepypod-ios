import Foundation

enum BiometricReportStage: String, Codable, CaseIterable, Sendable {
    case wake, light, deep, rem
    var title: String { self == .rem ? "REM" : rawValue.capitalized }
}
struct BiometricStageScore: Codable, Sendable {
    struct MatrixRow: Codable, Sendable {
        let wake: Double
        let light: Double
        let deep: Double
        let rem: Double
        subscript(_ stage: BiometricReportStage) -> Double {
            switch stage {
            case .wake: wake
            case .light: light
            case .deep: deep
            case .rem: rem
            }
        }
    }
    struct Matrix: Codable, Sendable {
        let wake: MatrixRow
        let light: MatrixRow
        let deep: MatrixRow
        let rem: MatrixRow
        subscript(_ stage: BiometricReportStage) -> MatrixRow {
            switch stage {
            case .wake: wake
            case .light: light
            case .deep: deep
            case .rem: rem
            }
        }
    }
    struct Stage: Codable, Sendable, Identifiable {
        let stage: BiometricReportStage
        let referenceMs: Double
        let predictedMs: Double
        let precision: Double?
        let recall: Double?
        let f1: Double?
        var id: BiometricReportStage { stage }
    }
    let agreement: Double?
    let macroF1: Double?
    let pairedDurationMs: Double
    let confusionMs: Matrix
    let perStage: [Stage]
    var supported: Bool {
        pairedDurationMs >= 0 && perStage.count == 4 && Set(perStage.map(\.stage)).count == 4
        && perStage.allSatisfy { $0.referenceMs >= 0 && $0.predictedMs >= 0 }
        && BiometricReportStage.allCases.allSatisfy { reference in BiometricReportStage.allCases.allSatisfy { confusionMs[reference][$0] >= 0 } }
    }
}
struct BiometricStageReport: Codable, Sendable {
    struct OwnSupport: Codable, Sendable {
        let outputMs: Double
        let pairedMs: Double
        let referenceMs: Double
        let agreement: Double?
        let outputCoverage: Double?
        let referenceCoverage: Double?
    }
    struct Night: Codable, Sendable, Identifiable {
        let cohortId: String
        let evaluationDurationMs: Double
        let commonSupport: BiometricReportPair<BiometricStageScore>
        let ownSupport: BiometricReportPair<OwnSupport>
        let commonAgreementDifference: Double?
        let commonMacroF1Difference: Double?
        let coverageReduced: Bool
        var id: String { cohortId }
    }
    struct Comparison: Codable, Sendable {
        let baseline: BiometricReportConfiguration
        let candidate: BiometricReportConfiguration
        let baselineHash: String
        let candidateHash: String
        let pooledCommonSupport: BiometricReportPair<BiometricStageScore>
        let nights: [Night]
    }
    let stageNightSummary: [Comparison]
    func validate(job: BiometricBacktestJob) throws {
        guard stageNightSummary.count <= 3, stageNightSummary.allSatisfy({ comparison in
            job.matches(comparison.baseline, hash: comparison.baselineHash) && job.matches(comparison.candidate, hash: comparison.candidateHash)
            && comparison.pooledCommonSupport.baseline.supported && comparison.pooledCommonSupport.candidate.supported
            && comparison.nights.count <= 60 && Set(comparison.nights.map(\.cohortId)).count == comparison.nights.count
            && comparison.nights.allSatisfy { $0.evaluationDurationMs >= 0 && $0.commonSupport.baseline.supported && $0.commonSupport.candidate.supported }
        }) else { throw BiometricBacktestInput.error("Stage details are unavailable or incompatible.") }
    }
}
