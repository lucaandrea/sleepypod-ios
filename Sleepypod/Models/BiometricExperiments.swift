import Foundation

struct BiometricExperimentProtocol: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        case comparison, stages = "stage_replay", waveform = "signal_replay"
        var title: String {
            switch self {
            case .comparison: "Compare stored readings"
            case .stages: "Replay sleep stages"
            case .waveform: "Replay retained waveforms"
            }
        }
    }
    struct Uncertainty: Codable, Equatable, Sendable {
        let version: String
        let seed: String
        let resamples: Int
        let minimumNights: Int
        var valid: Bool { version == "paired-night-percentile-v1" && (1...64).contains(seed.utf16.count) && (200...5000).contains(resamples) && (3...60).contains(minimumNights) }
    }
    let version: String
    let mode: Mode
    let waveformStages: Bool?
    let assumedStageCalibrationQuality: Double
    let pointToleranceMs: Int
    let clockOffsetMs: Int
    let nightUncertainty: Uncertainty?
    // Keep each frozen policy representation intact; old report hashes bind that representation.
    let objectivePolicy: JSONValue?
    let objectivePolicies: [JSONValue]?
    let stageObjectivePolicy: JSONValue?
    var includesStages: Bool { mode == .stages || (mode == .waveform && waveformStages == true) }
    var supportsUncertainty: Bool { includesStages || mode == .waveform }
    func validateEditorProtocol(for dataset: BiometricDataset) throws {
        guard dataset.available, dataset.validIdentity, dataset.manifest.supported,
              version == "descriptive-evaluation-v1",
              assumedStageCalibrationQuality.isFinite, (0...1).contains(assumedStageCalibrationQuality),
              (0...300000).contains(pointToleranceMs), (-3600000...3600000).contains(clockOffsetMs),
              nightUncertainty.map({ supportsUncertainty && $0.valid }) ?? true,
              objectivePolicy == nil, objectivePolicies == nil, stageObjectivePolicy == nil,
              includesStages || assumedStageCalibrationQuality == 0,
              (mode == .waveform) == (dataset.manifest.version == "waveform-dataset-manifest-v1"),
              mode != .waveform || dataset.manifest.capabilities.signalReplay,
              mode != .stages || dataset.manifest.capabilities.stageReplay,
              mode != .comparison || dataset.manifest.capabilities.comparison,
              mode == .waveform || waveformStages == nil else {
            throw BiometricBacktestInput.error("Complete the protocol within its stated limits and choose a mode supported by these retained inputs.")
        }
    }
}
struct BiometricExperiment: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let datasetId: String
    let side: Side
    let `protocol`: BiometricExperimentProtocol
    let protocolHash: String
    let holdoutAccesses: Int
    let createdAtMs: Double
    var validIdentity: Bool { UUID(uuidString: id) != nil && UUID(uuidString: datasetId) != nil && BiometricBacktestInput.isHash(protocolHash) && holdoutAccesses >= 0 && createdAtMs.isFinite && createdAtMs >= 0 && createdAtMs <= 9007199254740991 && createdAtMs.rounded() == createdAtMs }
}
struct BiometricExperimentPage: Codable, Sendable {
    struct Cursor: Codable, Equatable, Sendable { let createdAtMs: Double; let id: String }
    let items: [BiometricExperiment]
    let nextCursor: Cursor?
}
struct BiometricExperimentRequest: Codable, Equatable, Sendable {
    let datasetId: String
    let `protocol`: BiometricExperimentProtocol
    let idempotencyKey: String
    func validated() throws -> Self {
        _ = try BiometricBacktestInput.identifier(datasetId)
        guard (1...200).contains(idempotencyKey.utf16.count) else { throw BiometricBacktestInput.error("Missing experiment retry identity.") }
        return self
    }
    func matches(_ result: BiometricExperiment, side: Side) -> Bool {
        result.validIdentity && result.datasetId == datasetId && result.side == side && result.protocol == self.protocol
    }
}
