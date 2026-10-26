import SwiftUI

struct BiometricObservationReportScreen: View {
    let details: BiometricObservationDetailsWorkspace
    var body: some View {
        BiometricReportPage(title: "Observation report") {
            if let error = details.reportError { BiometricProfileError(error: error) }
            Button("Refresh report", systemImage: "arrow.clockwise") { Task { await details.loadReport() } }.disabled(details.loadingReport).accessibilityIdentifier("observations.refreshReport")
            if details.loadingReport && details.report == nil { ProgressView("Loading report…") }
            if let report = details.report {
                VStack(alignment: .leading, spacing: 12) {
                    Text(report.health.title).font(.title2).accessibilityIdentifier("observations.health")
                    BiometricProfileValue("Snapshot · UTC", value: ReferenceLabels.utc(report.capturedAtMs))
                    Text("Descriptive observations do not authorize applying a profile or establish validated improvement.").font(.footnote).foregroundStyle(Theme.text2)
                    ReportValues(rows: [("Saved sample times", String(report.observedSamples)), ("Planned observation intervals", String(report.expectedSlots)),
                                        ("Largest gap", ReportDisplay.number(report.maximumGapMs / 1000) + " s"), ("Attempts observed", String(report.attemptsObserved))])
                    ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in Text(BiometricObservationIssue.title(issue)).font(.footnote).foregroundStyle(Theme.amber) }
                }.cardStyle()
                ForEach(report.metrics) { metric in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(metric.metric.title).font(.headline)
                        ReportValues(rows: [("Active coverage", coverage(metric.current.coverage)), ("Candidate coverage", coverage(metric.candidate.coverage)),
                                            ("Coverage difference", coverage(metric.coverageDifference)), ("Active readings / intervals", "\(metric.current.usableCount) / \(metric.current.usableSlots)"),
                                            ("Candidate readings / intervals", "\(metric.candidate.usableCount) / \(metric.candidate.usableSlots)")])
                        ForEach(metric.issues, id: \.self) { Text(BiometricObservationIssue.title($0)).font(.footnote).foregroundStyle(Theme.amber) }
                    }.cardStyle()
                }
                Text("Missing observations remain missing. The window IBI variability index is not clinical RMSSD.").font(.footnote).foregroundStyle(Theme.text2)
                NavigationLink { BiometricObservationComparisonScreen(details: details) } label: { SettingsRow("Compare with reference measurements", icon: "doc.text.magnifyingglass", tile: true, chevron: true) }.cardStyle().accessibilityIdentifier("observations.compare")
                DisclosureGroup("Processing and context observations") {
                    VStack(alignment: .leading, spacing: 12) {
                        if let envelope = report.workerReceipt, let receipt = envelope["receipt"] {
                            if envelope["schema"] == .string("biometric-shadow-partial-receipt-v1") {
                                Text("Partial resource observations. Worker health is its last valid reply, not the complete attempt.").font(.footnote).foregroundStyle(Theme.amber)
                            }
                            BiometricProfileValue("Sampled worker memory peak", value: receipt["peakObservedRssBytes"]?.number.map { ReportDisplay.number($0 / 1048576) + " MiB" } ?? "Unavailable")
                            BiometricProfileValue("Memory samples", value: receipt["rssSamples"]?.number.map(ReportDisplay.number) ?? "Unavailable")
                            BiometricProfileValue("Largest memory observation gap", value: receipt["maximumObservationGapMs"]?.number.map { ReportDisplay.number($0 / 1000) + " s" } ?? "Unavailable")
                            Text("Summed process-group RSS is sampled. Short peaks between samples may be missed.").font(.footnote).foregroundStyle(Theme.text2)
                            DisclosureGroup("Exact resource receipt") { BiometricProfileIdentity(title: "Saved worker observations", value: envelope.formattedJSON) }
                        } else { Text("No worker resource receipt is available.").foregroundStyle(Theme.text2) }
                        Text("Presence and pump context are host observations, not proof of the live processor’s cached state.").font(.footnote).foregroundStyle(Theme.text2)
                        ReportValues(rows: [("Active-only samples", String(report.pairing.activeOnly)), ("Candidate-only samples", String(report.pairing.candidateOnly)), ("Unknown input identity", String(report.pairing.unknownInputIdentity))])
                        ForEach(Array(report.limitations.enumerated()), id: \.offset) { _, text in Text(text).font(.footnote).foregroundStyle(Theme.text2) }
                    }.padding(.top, 8)
                }.cardStyle().accessibilityIdentifier("observations.resources")
                evidence(report)
            }
        }.task { if details.report == nil { await details.loadReport() } }
    }
    private func evidence(_ report: BiometricObservationReport) -> some View {
        DisclosureGroup("Report evidence") {
            VStack(alignment: .leading, spacing: 10) {
                BiometricProfileIdentity(title: "Report hash", value: report.reportHash)
                BiometricProfileIdentity(title: "Snapshot hash", value: report.snapshotHash)
                BiometricProfileIdentity(title: "Plan hash", value: report.planHash)
                if let hash = report.executionPolicyHash { BiometricProfileIdentity(title: "Execution policy hash", value: hash) }
            }.padding(.top, 8)
        }.cardStyle().accessibilityIdentifier("observations.evidence")
    }
    private func coverage(_ value: Double?) -> String { value.map { $0.formatted(.percent.precision(.fractionLength(0...1))) } ?? "Unavailable" }
}
struct BiometricObservationComparisonScreen: View {
    let details: BiometricObservationDetailsWorkspace
    @State private var source = ""
    @State private var text = ""
    @State private var format = ReferenceTextParser.Format.csv
    var body: some View {
        BiometricReportPage(title: "Reference comparison") {
            ReferenceSideValue(side: details.initial.side)
            BiometricProfileValue("Sleeper identity", value: details.initial.subjectId)
            Text("Paste JSON records or CSV with recordKey, metric, value, unit, and timestamp (or start and end). Use times with an explicit UTC offset or Unix milliseconds. This comparison does not save a reference import.").font(.footnote).foregroundStyle(Theme.text2)
            VStack(alignment: .leading, spacing: 12) {
                if APIBackend.current.isDemo, details.initial.id == "60000000-0000-4000-8000-000000000001" {
                    Button("Load synthetic example reference") {
                        if let example = try? BiometricObservationExample.load() {
                            source = example.reference.source
                            format = .json
                            text = JSONValue.array(example.reference.rows).formattedJSON
                        }
                    }.accessibilityIdentifier("observations.exampleReference")
                }
                TextField("Reference source", text: $source).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("observations.referenceSource")
                BiometricReportMenu(title: "Reference format", selection: $format, options: ReferenceTextParser.Format.allCases) { $0.rawValue.uppercased() }.accessibilityIdentifier("observations.referenceFormat")
                Text("Comparison reference records").font(.headline)
                TextEditor(text: $text).font(.footnote.monospaced()).frame(minHeight: 170).scrollContentBackground(.hidden).accessibilityIdentifier("observations.referenceText")
                Text("At most 2000 records. The complete request must fit within 64 KiB.").font(.footnote).foregroundStyle(Theme.text2)
                Button("Compare reference") { Task { await details.compare(source: source, text: text, format: format) } }
                    .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("observations.compareReference")
            }.cardStyle().disabled(details.comparing)
            if details.comparing { ProgressView("Comparing reference…") }
            if let error = details.comparisonError { BiometricProfileError(error: error) }
            if let report = details.comparison {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Reference comparison snapshot").font(.headline).accessibilityIdentifier("observations.comparisonSnapshot")
                    Text(ReferenceLabels.utc(report.capturedAtMs)).font(.footnote.monospaced())
                    Text("An ongoing run may now contain more observations than the earlier health report.").font(.footnote).foregroundStyle(Theme.text2)
                    if let summary = report.referenceSummary {
                        ReportValues(rows: [("Accepted / rejected", "\(summary.accepted) / \(summary.rejected)"), ("Duplicates / unscorable", "\(summary.duplicates) / \(summary.unscorable)")])
                    }
                    ReportValues(rows: [("Reference records outside snapshot window", String(report.excludedBoundaryReferences)), ("Reference clock offset", ReportDisplay.number(report.alignment.clockOffsetMs / 1000) + " s"),
                                        ("Point tolerance", ReportDisplay.number(report.alignment.pointToleranceMs / 1000) + " s")])
                }.cardStyle()
                ForEach(report.metrics) { metric in
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(metric.metric.title) · \(metric.metric.unit)").font(.headline)
                        if let window = metric.windowMs { BiometricProfileValue("Metric window", value: ReportDisplay.number(window / 1000) + " s") }
                        let comparison = metric.comparison
                        Text(comparison.commonSupport.candidate.status.title)
                        ReportValues(rows: [("Shared reference pairs · active / candidate", "\(comparison.commonSupport.baseline.pairedCount) / \(comparison.commonSupport.candidate.pairedCount)"),
                                            ("Shared-timestamp MAE · active", ReportDisplay.number(comparison.commonSupport.baseline.metrics?.mae)),
                                            ("Shared-timestamp MAE · candidate", ReportDisplay.number(comparison.commonSupport.candidate.metrics?.mae)),
                                            ("Own-output reference coverage · active", ReportDisplay.percent(comparison.ownSupport.baseline.referenceCoverage)),
                                            ("Own-output reference coverage · candidate", ReportDisplay.percent(comparison.ownSupport.candidate.referenceCoverage)),
                                            ("Candidate timestamps lost / added", "\(comparison.lostObservationTimestamps) / \(comparison.addedObservationTimestamps)")])
                        if comparison.coverageReduced { Text("Candidate coverage was reduced. Lower error alone does not show improvement.").font(.footnote).foregroundStyle(Theme.amber) }
                        ForEach(metric.referenceExclusions.keys.sorted(), id: \.self) { key in
                            if let count = metric.referenceExclusions[key], count > 0 { BiometricProfileValue(ReportDisplay.label(key), value: String(count)) }
                        }
                    }.cardStyle()
                }
                Text("These results describe agreement with a reference. They do not establish clinical accuracy, independent holdout evidence, or permission to apply a profile.").font(.footnote).foregroundStyle(Theme.text2)
                DisclosureGroup("Comparison evidence") {
                    if let hash = report.referenceSummary?.contentHash { BiometricProfileIdentity(title: "Reference content hash", value: hash) }
                    BiometricProfileIdentity(title: "Comparison report hash", value: report.reportHash)
                    BiometricProfileIdentity(title: "Snapshot hash", value: report.snapshotHash)
                }.cardStyle()
            }
        }.onChange(of: source) { details.clearComparison() }.onChange(of: text) { details.clearComparison() }.onChange(of: format) { details.clearComparison() }
    }
}
enum BiometricObservationIssue {
    static func title(_ issue: String) -> String {
        switch issue {
        case "clock_skew": "Observation clocks are inconsistent."
        case "join_failed": "Candidate and active readings could not be paired reliably."
        case "observation_window_missed": "The observation window was missed."
        case "processor_failed": "Processing failed."
        case "simulated_demo": "Synthetic example; no hardware execution or qualification."
        case "worker_cleanup_unconfirmed": "Worker cleanup has not been confirmed."
        case "storage_quota": "The storage quota was reached."
        case "worker_stale": "Worker health observations are stale."
        case "observation_gap": "The observation gap exceeded the planned limit."
        case "no_observations": "No observations were saved."
        case "coverage_degraded", "candidate_coverage_below_minimum": "Candidate coverage fell below the planned limits."
        case "coverage_regression": "Candidate coverage declined relative to active processing."
        default: ReportDisplay.label(issue)
        }
    }
}
