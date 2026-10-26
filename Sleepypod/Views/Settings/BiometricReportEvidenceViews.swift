import SwiftUI

struct BiometricReportPolicyView: View {
    let report: BiometricEvaluationReport
    private var policies: [JSONValue] { report.protocol.objectivePolicies ?? report.protocol.objectivePolicy.map { [$0] } ?? [] }
    var body: some View {
        ForEach(Array(policies.enumerated()), id: \.offset) { _, policy in
            BiometricObjectivePolicyCard(policy: policy, stage: false, assessments: (report.objectiveAssessments ?? []).filter {
                $0.policy?["metric"] == policy["metric"] || ($0.policy == nil && report.protocol.objectivePolicies == nil)
            })
        }
        if let policy = report.protocol.stageObjectivePolicy { BiometricObjectivePolicyCard(policy: policy, stage: true, assessments: report.stageObjectiveAssessments ?? []) }
    }
}
struct BiometricObjectivePolicyCard: View {
    let policy: JSONValue
    let stage: Bool
    let assessments: [BiometricReportAssessment]
    var body: some View {
        DisclosureGroup(stage ? "Frozen stage objective thresholds" : "Frozen objective thresholds") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Thresholds are part of this experiment. Supplying thresholds does not qualify a promotion policy.").font(.footnote).foregroundStyle(Theme.text2)
                if stage { Text("Agreement with the named reference does not establish clinical stage accuracy.").font(.footnote).foregroundStyle(Theme.text2) }
                ReportValues(rows: entries(policy))
                ForEach(Array(assessments.enumerated()), id: \.offset) { _, assessment in
                    Divider()
                    Text("\(assessment.candidate.title(waveform: true)) / \(assessment.baseline.title(waveform: true))").font(.headline)
                    Text(assessment.status.title)
                    Text(assessment.designated ? "Designated policy" : "Policy is not designated").foregroundStyle(Theme.text2)
                    ForEach(Array(assessment.missingEvidence.enumerated()), id: \.offset) { _, reason in Text("Missing evidence: \(ReportDisplay.label(reason))").font(.footnote) }
                    ForEach(Array(assessment.failedThresholds.enumerated()), id: \.offset) { _, reason in Text("Threshold failed: \(ReportDisplay.label(reason))").font(.footnote).foregroundStyle(Theme.amber) }
                }
            }.padding(.top, 10)
        }.cardStyle().accessibilityIdentifier(stage ? "reports.stagePolicy" : "reports.numericPolicy")
    }
    /// Preserve frozen nested thresholds while presenting their full paths as readable labels.
    private func entries(_ value: JSONValue, prefix: String = "") -> [(String, String)] {
        guard case .object(let fields) = value else { return [(ReportDisplay.label(prefix), display(value))] }
        return fields.keys.sorted().flatMap { key in entries(fields[key]!, prefix: prefix.isEmpty ? key : prefix + "." + key) }
    }
    private func display(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): text
        case .number(let number): ReportDisplay.number(number)
        case .bool(let enabled): enabled ? "Yes" : "No"
        case .array(let values): values.isEmpty ? "None" : values.map(display).joined(separator: ", ")
        case .null: "Not specified"
        case .object: "Nested thresholds"
        }
    }
}

struct BiometricReplayResourcesView: View {
    let report: BiometricEvaluationReport
    private var resources: BiometricReplayResources? { report.waveform?["resources"].flatMap { try? JSONDecoder().decode(BiometricReplayResources.self, from: JSONEncoder().encode($0)) } }
    private var operations: BiometricReplayOperations? { report.jobOperations.flatMap { try? JSONDecoder().decode(BiometricReplayOperations.self, from: JSONEncoder().encode($0)) } }
    var body: some View {
        DisclosureGroup("Replay processing costs") {
            VStack(alignment: .leading, spacing: 12) {
                if let resources, resources.supported {
                    ReportValues(rows: [("Measured Python processes", "\(resources.measuredProcesses) of \(resources.expectedProcesses)"),
                                        ("Total Python wall time", duration(resources.totalWallMs)), ("Total Python CPU time", duration(resources.totalCpuMs)),
                                        ("Largest Python process peak memory", memory(resources.largestProcessPeakRssBytes))])
                    Text("Sequential Python work through result generation. Memory is the largest process lifetime peak. These measurements exclude coordinator and scoring costs and do not establish live ingestion health.").font(.footnote).foregroundStyle(Theme.text2)
                } else if report.waveform?["resources"] != nil { BiometricProfileError(error: "Replay process measurements have an unsupported format.") }
                else { Text("This report does not include replay process measurements.").foregroundStyle(Theme.text2) }
                if let operations, operations.supported {
                    Divider(); Text("Job health observations").font(.headline)
                    ReportValues(rows: [("Job time through publication preparation", duration(operations.wallMs)), ("Ingestion samples / admission checks", "\(operations.ingestion.samples) / \(operations.ingestion.checks)"),
                                        ("Largest observed ingestion age", duration(operations.ingestion.maximumObservedAgeMs)), ("Largest observation gap", duration(operations.ingestion.maximumObservationGapMs))])
                    if !operations.ingestion.allChecksMeasured { Text("Some health evidence is unavailable or changed qualification during execution.").font(.footnote).foregroundStyle(Theme.amber) }
                    Text("Health was sampled at admission checks, normally five seconds apart. Unobserved intervals are not continuous health measurements.").font(.footnote).foregroundStyle(Theme.text2)
                    if let measured = operations.memory {
                        ReportValues(rows: [("Observed process-group peak RSS", memory(measured.peakObservedRssBytes)), ("Memory samples / attempts", "\(measured.samples) / \(measured.attempts)"), ("Largest memory observation gap", duration(measured.maximumObservationGapMs))])
                        Text("Sampled summed RSS covers the coordinator and workers. Shared pages may be counted more than once, and short peaks between observations may be missed.").font(.footnote).foregroundStyle(Theme.text2)
                    }
                } else if report.jobOperations != nil { BiometricProfileError(error: "Job health observations have an unsupported format.") }
            }.padding(.top, 10)
        }.cardStyle().accessibilityIdentifier("reports.resources")
    }
    private func duration(_ milliseconds: Double?) -> String { milliseconds.map { ReportDisplay.number($0 / 1000) + " s" } ?? "Unavailable" }
    private func memory(_ bytes: Double?) -> String { bytes.map { ReportDisplay.number($0 / (1024 * 1024)) + " MiB" } ?? "Unavailable" }
}
