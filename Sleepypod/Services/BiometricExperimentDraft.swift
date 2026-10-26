import Foundation
import Observation

@MainActor @Observable final class BiometricExperimentDraft {
    let dataset: BiometricDataset
    var mode: BiometricExperimentProtocol.Mode
    var waveformStages = false
    var quality = ""
    var tolerance = "30000"
    var offset = "0"
    var estimateUncertainty = false
    var seed = ""
    var resamples = "1000"
    var minimumNights = "3"
    init(dataset: BiometricDataset) { self.dataset = dataset; mode = dataset.manifest.version == "waveform-dataset-manifest-v1" ? .waveform : .comparison }
    var includesStages: Bool { mode == .stages || (mode == .waveform && waveformStages) }
    var supportsUncertainty: Bool { includesStages || mode == .waveform }
    var allowedModes: [BiometricExperimentProtocol.Mode] {
        if dataset.manifest.version == "waveform-dataset-manifest-v1" { return dataset.manifest.capabilities.signalReplay ? [.waveform] : [] }
        return [.comparison, .stages].filter { $0 == .stages ? dataset.manifest.capabilities.stageReplay : dataset.manifest.capabilities.comparison }
    }
    var valid: Bool { (try? request()) != nil }
    func request(key: String = UUID().uuidString.lowercased()) throws -> BiometricExperimentRequest {
        let calibration = includesStages ? try number(quality) : 0
        let uncertainty: BiometricExperimentProtocol.Uncertainty? = estimateUncertainty && supportsUncertainty
            ? .init(version: "paired-night-percentile-v1", seed: seed, resamples: try integer(resamples), minimumNights: try integer(minimumNights)) : nil
        let evaluationProtocol = BiometricExperimentProtocol(version: "descriptive-evaluation-v1", mode: mode, waveformStages: mode == .waveform ? waveformStages : nil,
            assumedStageCalibrationQuality: calibration, pointToleranceMs: try integer(tolerance), clockOffsetMs: try integer(offset), nightUncertainty: uncertainty,
            objectivePolicy: nil, objectivePolicies: nil, stageObjectivePolicy: nil)
        try evaluationProtocol.validateEditorProtocol(for: dataset)
        return try .init(datasetId: dataset.id, protocol: evaluationProtocol, idempotencyKey: key).validated()
    }
    private func number(_ text: String) throws -> Double {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else { throw BiometricBacktestInput.error("Enter a finite number; blank fields do not mean zero.") }
        return value
    }
    private func integer(_ text: String) throws -> Int {
        let value = try number(text)
        guard value.rounded() == value, value >= -9007199254740991, value <= 9007199254740991 else { throw BiometricBacktestInput.error("Enter a whole number within the stated limits.") }
        return Int(value)
    }
}
