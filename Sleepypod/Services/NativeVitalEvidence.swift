import Foundation
import FreeSleepKit

enum NativeVitalEvidence {
    /// These SQL aggregates cover the requested range, not exclusively sleep or occupied intervals.
    static func facts(_ summary: VitalsSummary?) -> [NativeSleepFact] {
        guard let summary else { return [.init(id: "pod.vitals", text: "Pod vital summary could not be read for this range. Missing vitals are unknown.")] }
        var result = [NativeSleepFact(id: "pod.processing", text: processing(summary))]
        if let value = summary.avgHeartRate, value.isFinite, value > 0 {
            result.append(.init(id: "pod.heart", text: "Mean Pod heart-rate estimate across available readings in this range: \(number(value)) bpm. These are piezo-derived estimates, not clinical readings; the aggregate is not limited to sleep or occupied intervals."))
        }
        if let value = summary.avgBreathingRate, value.isFinite, value > 0 {
            result.append(.init(id: "pod.breathing", text: "Mean Pod breathing-rate estimate across available readings in this range: \(number(value)) breaths/min. The aggregate is not limited to sleep or occupied intervals."))
        }
        if let value = summary.avgHRV, value.isFinite, value >= 0, summary.provenance?.hasKnownSDNN == true {
            result.append(.init(id: "pod.hrv", text: "Mean recorded Pod SDNN estimate across available readings: \(number(value)) ms. This range aggregate is not exclusively sleep; it is distinct from Apple Health or Watch SDNN."))
        } else {
            result.append(.init(id: "pod.hrvCoverage", text: "No compatible recorded SDNN aggregate is available. Missing, legacy, mixed-definition or other HRV metrics are not relabeled as SDNN."))
        }
        if result.allSatisfy({ !["pod.heart", "pod.breathing", "pod.hrv"].contains($0.id) }) {
            result.append(.init(id: "pod.vitals", text: "No qualified numeric Pod vital measurements are available in this range. Missing values are unknown, not zero."))
        }
        return result
    }
    private static func number(_ value: Double) -> String { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value) }
    private static func processing(_ summary: VitalsSummary) -> String {
        let count = summary.recordCount.map { "\($0) source rows. " } ?? "Source row count is unavailable. "
        guard let provenance = summary.provenance, provenance.interpretation == "original_observations",
              provenance.configurationCount >= 0, provenance.unknownConfigurationRows >= 0 else {
            return count + "Processing provenance is unavailable. Means retain original estimates and cannot establish a consistent processing method or trend."
        }
        return count + "Original observations from \(provenance.configurationCount) known processing configurations; \(provenance.unknownConfigurationRows) rows have unknown configuration. "
            + (provenance.configurationCount == 1 && provenance.unknownConfigurationRows == 0
                ? "One recorded processing configuration; this is not a diagnostic validation."
                : "Mixed or unknown processing limits comparisons; this is not one consistently reprocessed baseline.")
    }
}
