import Foundation
import Observation

@MainActor @Observable final class BiometricBacktestSubmissionDraft {
    struct Candidate: Codable, Equatable, Sendable {
        let id: String
        let hash: String
        let generation: Int
    }
    struct Selection: Codable, Equatable, Sendable {
        let experimentId: String
        let datasetHash: String
        let protocolHash: String
        let candidate: Candidate
        let split: BiometricEvaluationSplit
    }
    let experiment: BiometricExperiment
    let dataset: BiometricDataset
    private(set) var candidate: Candidate?
    var split = BiometricEvaluationSplit.tuning { didSet { if oldValue != split { acknowledged = nil } } }
    private(set) var acknowledged: Selection?
    init(experiment: BiometricExperiment, dataset: BiometricDataset) { self.experiment = experiment; self.dataset = dataset }
    var availableSplits: [BiometricEvaluationSplit] {
        let selected = Set(dataset.manifest.splitProtocol.assignments.map(\.split))
        return BiometricEvaluationSplit.allCases.filter { selected.contains($0.rawValue) }
    }
    var selection: Selection? {
        candidate.map { .init(experimentId: experiment.id, datasetHash: dataset.contentHash, protocolHash: experiment.protocolHash, candidate: $0, split: split) }
    }
    var holdoutAcknowledged: Bool { selection != nil && acknowledged == selection }
    func acknowledgeHoldout(_ value: Bool) { acknowledged = value && split == .holdout ? selection : nil }
    func select(_ revision: BiometricProfileRevision, overview: BiometricProfileOverview) throws {
        guard revision.side == experiment.side, overview.desired.binding.side == experiment.side,
              UUID(uuidString: revision.id) != nil, BiometricBacktestInput.isHash(revision.resolvedHash), overview.desired.binding.generation >= 0 else {
            throw BiometricBacktestInput.error("Choose a candidate and current baseline for this bed side.")
        }
        candidate = .init(id: revision.id, hash: revision.resolvedHash, generation: overview.desired.binding.generation)
        acknowledged = nil
    }
    func request(currentGeneration: Int, key: String = UUID().uuidString.lowercased()) throws -> BiometricBacktestSubmission {
        guard let candidate, candidate.generation == currentGeneration, dataset.available, dataset.validIdentity,
              experiment.validIdentity, experiment.datasetId == dataset.id, experiment.side == dataset.side,
              experiment.protocol.version == "descriptive-evaluation-v1", dataset.manifest.supported,
              availableSplits.contains(split), split != .holdout || holdoutAcknowledged else {
            throw BiometricBacktestInput.error("Review retained inputs, a current candidate baseline and the selected partition before queueing.")
        }
        return try .init(experimentId: experiment.id, candidateRevisionId: candidate.id, expectedBindingGeneration: candidate.generation, split: split, idempotencyKey: key).validated()
    }
}
