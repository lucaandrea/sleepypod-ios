import SwiftUI

struct BiometricExperimentProtocolView: View {
    let evaluationProtocol: BiometricExperimentProtocol
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Frozen protocol").font(.headline)
            BiometricProfileValue("Mode", value: evaluationProtocol.mode.title)
            if evaluationProtocol.mode == .waveform { BiometricProfileValue("Also replay sleep stages", value: evaluationProtocol.waveformStages == true ? "Yes" : "No") }
            if evaluationProtocol.includesStages {
                BiometricProfileValue("Assumed calibration quality", value: evaluationProtocol.assumedStageCalibrationQuality.formatted())
                Text("Replay assumption; not a recovered sensor measurement.").font(.footnote).foregroundStyle(Theme.text2)
            }
            BiometricProfileValue("Matching tolerance", value: "\(evaluationProtocol.pointToleranceMs) ms")
            BiometricProfileValue("Pod timestamp offset", value: "\(evaluationProtocol.clockOffsetMs) ms")
            if let uncertainty = evaluationProtocol.nightUncertainty {
                Text("Exploratory whole-night uncertainty").font(.headline)
                BiometricProfileIdentity(title: "Sampling seed", value: uncertainty.seed)
                BiometricProfileValue("Resamples", value: String(uncertainty.resamples))
                BiometricProfileValue("Minimum paired nights", value: String(uncertainty.minimumNights))
                Text("A reporting threshold, not a validated sample-size requirement. Insufficient or degenerate nights yield no interval.").font(.footnote).foregroundStyle(Theme.text2)
            } else { BiometricProfileValue("Whole-night uncertainty", value: "Not requested") }
            if evaluationProtocol.objectivePolicy != nil || evaluationProtocol.objectivePolicies != nil || evaluationProtocol.stageObjectivePolicy != nil {
                Text("This protocol includes frozen objective policies. Inspect the complete protocol below. The controller determines whether results qualify for activation.").font(.footnote).foregroundStyle(Theme.text2)
            }
            DisclosureGroup("Complete protocol") {
                if let value = try? JSONValue.encoded(evaluationProtocol) { Text(value.formattedJSON).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }.accessibilityIdentifier("experiments.completeProtocol")
        }.cardStyle()
    }
}
