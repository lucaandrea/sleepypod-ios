import SwiftUI

struct BiometricStageReportScreen: View {
    let report: BiometricStageReport
    let summaries: [BiometricEvaluationReport.StageSummary]
    let waveform: Bool
    var body: some View {
        BiometricReportPage(title: "Stage comparisons") {
            Text("Common support is the overlap of all evaluated configurations and eligible reference intervals. Each configuration’s own-support scores may describe different portions of the night.").font(.footnote).foregroundStyle(Theme.text2)
            Text("Output coverage uses evaluated time; reference coverage uses eligible reference time. Higher scores with reduced coverage are not sufficient evidence of improvement.").font(.footnote).foregroundStyle(Theme.text2)
            ForEach(Array(report.stageNightSummary.enumerated()), id: \.offset) { _, comparison in
                NavigationLink {
                    BiometricStageComparisonScreen(comparison: comparison, summary: summaries.first { $0.baseline == comparison.baseline && $0.candidate == comparison.candidate && $0.baselineHash == comparison.baselineHash && $0.candidateHash == comparison.candidateHash }, waveform: waveform)
                } label: {
                    SettingsRow("\(comparison.candidate.title(waveform: waveform)) / \(comparison.baseline.title(waveform: waveform))", icon: "chart.bar", tile: true, chevron: true)
                }.cardStyle().accessibilityIdentifier("reports.stageComparison.\(comparison.baseline.rawValue).\(comparison.candidate.rawValue)")
            }
        }
    }
}
struct BiometricStageComparisonScreen: View {
    let comparison: BiometricStageReport.Comparison
    let summary: BiometricEvaluationReport.StageSummary?
    let waveform: Bool
    @State private var page = 0
    var body: some View {
        BiometricReportPage(title: "Stage agreement") {
            Text("\(comparison.candidate.title(waveform: waveform)) / \(comparison.baseline.title(waveform: waveform))").font(.headline)
            if let summary {
                VStack(alignment: .leading, spacing: 12) {
                    ReportValues(rows: [("Scored / unscored nights", "\(summary.scoredNights) / \(summary.unscoredNights)"), ("Nights with reduced coverage", "\(summary.coverageReducedNights)"),
                                        ("Higher / lower / unchanged agreement", "\(summary.improvedAgreementNights) / \(summary.regressedAgreementNights) / \(summary.unchangedAgreementNights)"),
                                        ("Equal-night mean agreement difference", ReportDisplay.percent(summary.equalNightMeanAgreementDifference))])
                    Text("Equal-night differences and pooled duration scores use different weighting. Consider coverage loss alongside score changes.").font(.footnote).foregroundStyle(Theme.text2)
                    BiometricReportUncertaintyView(status: summary.uncertainty.status, interval: summary.uncertainty.interval, limitations: summary.uncertainty.limitations, percent: true)
                }.cardStyle()
            }
            DisclosureGroup("Pooled stage confusion") {
                Text(comparison.baseline.title(waveform: waveform)).font(.headline).padding(.top, 10)
                BiometricStageScoresView(score: comparison.pooledCommonSupport.baseline)
                Divider()
                Text(comparison.candidate.title(waveform: waveform)).font(.headline)
                BiometricStageScoresView(score: comparison.pooledCommonSupport.candidate)
            }.cardStyle().accessibilityIdentifier("reports.confusion")
            ForEach(Array(comparison.nights.dropFirst(page * 10).prefix(10))) { night in
                NavigationLink { BiometricStageNightScreen(night: night, baseline: comparison.baseline, candidate: comparison.candidate, waveform: waveform) } label: { Label("Night \(night.cohortId)", systemImage: "moon") }
                    .accessibilityIdentifier("reports.stageNight.\(night.cohortId)")
            }
            ReportPagination(page: $page, count: comparison.nights.count)
        }
    }
}
struct BiometricStageNightScreen: View {
    let night: BiometricStageReport.Night
    let baseline: BiometricReportConfiguration
    let candidate: BiometricReportConfiguration
    let waveform: Bool
    var body: some View {
        BiometricReportPage(title: "Night stage coverage") {
            VStack(alignment: .leading, spacing: 12) {
                Text(night.cohortId).font(.headline)
                BiometricProfileValue("Evaluated time", value: ReportDisplay.minutes(night.evaluationDurationMs))
                Text(night.coverageReduced ? "Coverage reduced in at least one evaluated window" : "No coverage reduction detected").foregroundStyle(night.coverageReduced ? Theme.amber : Theme.text2)
                BiometricProfileValue("Common-support agreement difference", value: ReportDisplay.percent(night.commonAgreementDifference))
                BiometricProfileValue("Common-support macro F1 difference", value: ReportDisplay.percent(night.commonMacroF1Difference))
            }.cardStyle()
            ForEach([false, true], id: \.self) { isCandidate in
                let own = isCandidate ? night.ownSupport.candidate : night.ownSupport.baseline
                VStack(alignment: .leading, spacing: 12) {
                    Text((isCandidate ? candidate : baseline).title(waveform: waveform)).font(.headline)
                    Text("Own available intervals").font(.subheadline).foregroundStyle(Theme.text2)
                    ReportValues(rows: [("Agreement", ReportDisplay.percent(own.agreement)), ("Output coverage", ReportDisplay.percent(own.outputCoverage)), ("Reference coverage", ReportDisplay.percent(own.referenceCoverage)),
                                        ("Output time", ReportDisplay.minutes(own.outputMs)), ("Paired time", ReportDisplay.minutes(own.pairedMs)), ("Eligible reference time", ReportDisplay.minutes(own.referenceMs))])
                    DisclosureGroup("Common-support scores") { BiometricStageScoresView(score: isCandidate ? night.commonSupport.candidate : night.commonSupport.baseline).padding(.top, 8) }
                }.cardStyle()
            }
        }
    }
}
struct BiometricStageScoresView: View {
    let score: BiometricStageScore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReportValues(rows: [("Common paired time", ReportDisplay.minutes(score.pairedDurationMs)), ("Agreement", ReportDisplay.percent(score.agreement)), ("Macro F1", ReportDisplay.percent(score.macroF1))])
            Text("Confusion durations · reference to prediction").font(.subheadline)
            ForEach(BiometricReportStage.allCases, id: \.self) { reference in
                DisclosureGroup("Reference: \(reference.title)") {
                    ForEach(BiometricReportStage.allCases, id: \.self) { predicted in
                        BiometricProfileValue("Predicted \(predicted.title)", value: ReportDisplay.minutes(score.confusionMs[reference][predicted]))
                    }
                }
            }
            Text("Per-stage scores on common paired intervals").font(.subheadline)
            ForEach(score.perStage) { row in
                DisclosureGroup(row.stage.title) {
                    ReportValues(rows: [("Reference time", ReportDisplay.minutes(row.referenceMs)), ("Predicted time", ReportDisplay.minutes(row.predictedMs)),
                                        ("Precision", ReportDisplay.percent(row.precision)), ("Recall", ReportDisplay.percent(row.recall)), ("F1", ReportDisplay.percent(row.f1))])
                }
            }
        }
    }
}
