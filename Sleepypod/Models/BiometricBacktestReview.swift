import Foundation

struct BiometricBacktestReview: Codable, Equatable, Sendable {
    let side: Side
    let datasetId: String
    let datasetHash: String
    let protocolHash: String
    let candidateHash: String
    let scope: BiometricBacktestJob.Scope
    let holdoutAcknowledged: Bool
    let request: BiometricBacktestSubmission
    func matches(_ job: BiometricBacktestJob) -> Bool {
        job.validIdentity && job.experimentId == request.experimentId && job.datasetId == datasetId && job.datasetHash == datasetHash
        && job.split == request.split && job.evaluationScope == scope
        && job.configurations.filter { $0.label == "candidate" && $0.revisionId == request.candidateRevisionId && $0.hash == candidateHash }.count == 1
    }
}

struct BiometricBacktestJobIdentity: Codable, Equatable, Sendable {
    let side: Side
    let id: String
    let experimentId: String
    let datasetId: String
    let datasetHash: String
    let evaluatorBuildHash: String
    let split: BiometricEvaluationSplit
    let configurations: [BiometricBacktestJob.Configuration]
    init(side: Side, job: BiometricBacktestJob) {
        self.side = side; id = job.id; experimentId = job.experimentId; datasetId = job.datasetId
        datasetHash = job.datasetHash; evaluatorBuildHash = job.evaluatorBuildHash; split = job.split; configurations = job.configurations
    }
    func matches(_ job: BiometricBacktestJob) -> Bool {
        job.validIdentity && job.id == id && job.experimentId == experimentId && job.datasetId == datasetId && job.datasetHash == datasetHash
        && job.evaluatorBuildHash == evaluatorBuildHash && job.split == split && job.configurations == configurations
    }
}

extension BiometricExperimentProtocol {
    var backtestScope: BiometricBacktestJob.Scope {
        switch mode {
        case .comparison: .comparison
        case .stages: .stages
        case .waveform: .waveform
        }
    }
}
