import SwiftUI

struct BiometricNumericReportScreen: View {
    let report: BiometricNumericReport
    let waveform: Bool
    @State private var page = 0
    @State private var metric = BiometricReportMetric.heartRate
    var body: some View {
        BiometricReportPage(title: "Numerical comparisons") {
            Text(waveform ? "Shared-timestamp scores use readings available in every configuration. Differences describe agreement with a reference." : "These scores compare original stored readings. Identical results across profiles do not validate numerical parameter changes.").font(.footnote).foregroundStyle(Theme.text2)
            Text("Reference coverage counts eligible records paired. Output coverage counts observations with a value; it is not continuous time coverage. The window IBI variability index is not clinical beat-to-beat RMSSD.").font(.footnote).foregroundStyle(Theme.text2)
            Text("Nights").font(.headline)
            if report.nights.isEmpty { Text("No nights in this report.").foregroundStyle(Theme.text2) }
            ForEach(Array(report.nights.dropFirst(page * 10).prefix(10))) { night in
                NavigationLink { BiometricNumericNightScreen(night: night, waveform: waveform) } label: { Label("Night \(night.cohortId)", systemImage: "moon") }
                    .accessibilityIdentifier("reports.night.\(night.cohortId)")
            }
            ReportPagination(page: $page, count: report.nights.count)
            if waveform {
                BiometricReportMenu(title: "Summary metric", selection: $metric, options: BiometricReportMetric.allCases) { "\($0.title) · \($0.unit)" }
                    .accessibilityIdentifier("reports.summaryMetric")
                ForEach(Array((report.numericNightSummary ?? []).filter { $0.metric == metric }.enumerated()), id: \.offset) { _, summary in
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(summary.metric.title) · \(summary.metric.unit)").font(.headline)
                        Text("\(summary.candidate.title(waveform: true)) / \(summary.baseline.title(waveform: true))")
                        ReportValues(rows: [("Scored / unscored nights", "\(summary.scoredNights) / \(summary.unscoredNights)"), ("Nights with reduced coverage", "\(summary.coverageReducedNights)"),
                                            ("Lower / higher / unchanged error", "\(summary.improvedErrorNights) / \(summary.regressedErrorNights) / \(summary.unchangedErrorNights)"),
                                            ("Equal-night mean MAE difference", ReportDisplay.number(summary.equalNightMeanMaeDifference)),
                                            ("Pooled shared MAE · baseline", ReportDisplay.number(summary.pooledCommonSupport.baseline.mae)), ("Pooled shared MAE · comparison", ReportDisplay.number(summary.pooledCommonSupport.candidate.mae))])
                        Text("Night differences weight nights equally. Pooled scores weight all reference pairs equally. Errors use the metric unit.").font(.footnote).foregroundStyle(Theme.text2)
                        BiometricReportUncertaintyView(status: summary.uncertainty.status, interval: summary.uncertainty.interval, limitations: summary.uncertainty.limitations, percent: false)
                    }.cardStyle()
                }
                if let groups = report.numericSubgroupSummary, !groups.isEmpty {
                    DisclosureGroup("Reference-defined subgroups") {
                        Text("Groups use native reference times and record types. Half-window groups exclude intervals crossing the midpoint. Groups overlap; these are not independent experiments or motion/artifact groups.").font(.footnote).foregroundStyle(Theme.text2)
                        if !groups.contains(where: { $0.summary.metric == metric }) { Text("No subgroup scores for this metric.").foregroundStyle(Theme.text2) }
                        ForEach(Array(groups.filter { $0.summary.metric == metric }.enumerated()), id: \.offset) { _, group in
                            VStack(alignment: .leading, spacing: 8) {
                                Divider()
                                Text("\(group.name.title) · \(group.summary.metric.title)").font(.headline)
                                Text("\(group.summary.candidate.title(waveform: true)) / \(group.summary.baseline.title(waveform: true))")
                                ReportValues(rows: [("Scored / unscored nights", "\(group.summary.scoredNights) / \(group.summary.unscoredNights)"),
                                                    ("Equal-night mean MAE difference", ReportDisplay.number(group.summary.equalNightMeanMaeDifference)),
                                                    ("Intervals excluded at midpoints", "\(group.excludedBoundaryReferenceCount)")])
                            }.padding(.top, 8)
                        }
                    }.cardStyle().accessibilityIdentifier("reports.subgroups")
                }
            }
        }
    }
}

struct BiometricNumericNightScreen: View {
    let night: BiometricNumericReport.Night
    let waveform: Bool
    var body: some View {
        BiometricReportPage(title: "Night comparisons") {
            Text(night.cohortId).font(.headline)
            if waveform {
                if let comparisons = night.numericComparisons {
                    ForEach(Array(comparisons.enumerated()), id: \.offset) { _, window in
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Shared-timestamp comparisons").font(.headline)
                            BiometricProfileDate(title: "Window starts", milliseconds: window.startMs)
                            BiometricProfileDate(title: "Window ends", milliseconds: window.endMs)
                            Text("Differences are comparison minus baseline. Negative error differences mean lower error. Dropping readings can reduce own-support error; duplicate timestamps are excluded from shared support.").font(.footnote).foregroundStyle(Theme.text2)
                            ForEach(Array(window.metrics.enumerated()), id: \.offset) { _, row in
                                DisclosureGroup("\(row.metric.title) · \(row.candidate.title(waveform: true)) / \(row.baseline.title(waveform: true))") {
                                    ReportValues(rows: [("Shared observations", "\(row.commonObservationCount)"), ("Baseline shared MAE", ReportDisplay.number(row.commonSupport.baseline.metrics?.mae)),
                                                        ("Comparison shared MAE", ReportDisplay.number(row.commonSupport.candidate.metrics?.mae)), ("Shared MAE difference", ReportDisplay.number(row.differences.commonMae)),
                                                        ("Own-support MAE difference", ReportDisplay.number(row.differences.ownMae)), ("Lost / added readings", "\(row.lostObservationTimestamps) / \(row.addedObservationTimestamps)"),
                                                        ("Ambiguous timestamps · baseline / comparison", "\(row.ambiguousObservationTimestamps.baseline) / \(row.ambiguousObservationTimestamps.candidate)")]).padding(.top, 8)
                                    if row.coverageReduced { Text("Coverage reduced").foregroundStyle(Theme.amber) }
                                }
                            }
                        }.cardStyle()
                    }
                } else { Text("Shared-timestamp comparisons are unavailable in this report.").foregroundStyle(Theme.text2) }
            }
            ForEach(night.evaluations, id: \.label) { evaluation in
                VStack(alignment: .leading, spacing: 12) {
                    Text(evaluation.label.title(waveform: waveform)).font(.headline)
                    BiometricProfileIdentity(title: "Configuration", value: evaluation.configHash)
                    ForEach(Array(evaluation.windows.enumerated()), id: \.offset) { _, window in
                        BiometricProfileDate(title: "Window starts", milliseconds: window.startMs)
                        BiometricProfileDate(title: "Window ends", milliseconds: window.endMs)
                        Text("\(waveform ? "Recomputed" : "Stored") observations: \(window.observationCount)")
                        ForEach(window.numeric, id: \.metric) { row in
                            DisclosureGroup("\(row.metric.title) · \(row.status.title)") {
                                ReportValues(rows: [("Mean absolute error", ReportDisplay.number(row.metrics?.mae)), ("Median absolute error", ReportDisplay.number(row.metrics?.medianAbsoluteError)),
                                                    ("95th percentile absolute error", ReportDisplay.number(row.metrics?.p95AbsoluteError)), ("Signed bias · Pod minus reference", ReportDisplay.number(row.metrics?.signedBias)),
                                                    ("Paired records", "\(row.pairedCount)"), ("Reference coverage", ReportDisplay.percent(row.referenceCoverage)), ("Output coverage", ReportDisplay.percent(row.outputCoverage)),
                                                    ("Unmatched references / observations", "\(row.unmatchedReferences) / \(row.unmatchedObservations)")]).padding(.top, 8)
                                Text("Errors in \(row.metric.unit)").font(.footnote).foregroundStyle(Theme.text2)
                                ForEach(row.exclusions.keys.sorted(), id: \.self) { reason in BiometricProfileValue(ReportDisplay.label(reason), value: "\(row.exclusions[reason] ?? 0)") }
                            }.accessibilityIdentifier("reports.score.\(evaluation.label.rawValue).\(row.metric.rawValue)")
                        }
                    }
                }.cardStyle()
            }
        }
    }
}

struct BiometricReportPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView { LazyVStack(alignment: .leading, spacing: 18) { content() }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity) }
            .background(Theme.background).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}
struct ReportValues: View {
    let rows: [(String, String)]
    var body: some View { VStack(alignment: .leading, spacing: 10) { ForEach(Array(rows.enumerated()), id: \.offset) { _, row in BiometricProfileValue(row.0, value: row.1) } } }
}

/// The menu label wraps at full Dynamic Type size; the system menu retains native selection marks.
struct BiometricReportMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let name: (Value) -> String
    var body: some View {
        Menu {
            Picker(title, selection: $selection) { ForEach(options, id: \.self) { Text(name($0)).tag($0) } }
        } label: {
            HStack(spacing: 12) {
                Text(name(selection)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
        }.accessibilityLabel(title).accessibilityValue(name(selection))
    }
}
struct ReportPagination: View {
    @Binding var page: Int
    let count: Int
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { previous; Spacer(); next }
            VStack(alignment: .leading, spacing: 12) { previous; next }
        }
    }
    private var previous: some View { Button("Previous nights", systemImage: "chevron.left") { page -= 1 }.disabled(page == 0).opacity(page == 0 ? 0.4 : 1) }
    private var next: some View { Button("Next nights", systemImage: "chevron.right") { page += 1 }.disabled((page + 1) * 10 >= count).opacity((page + 1) * 10 >= count ? 0.4 : 1) }
}
struct BiometricReportUncertaintyView: View {
    let status: BiometricReportUncertainty.Status
    let interval: BiometricReportInterval?
    let limitations: [String]
    let percent: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(status.title)
            if let interval { Text("Exploratory 95% interval: \(display(interval.lower)) to \(display(interval.upper))") }
            ForEach(Array(limitations.enumerated()), id: \.offset) { _, item in Text(item).font(.footnote).foregroundStyle(Theme.text2) }
        }
    }
    private func display(_ value: Double) -> String { percent ? ReportDisplay.percent(value) : ReportDisplay.number(value) }
}
