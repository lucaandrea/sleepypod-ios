import SwiftUI

struct PersonalReportCard: View {
    let report: PersonalSleepReport
    var body: some View {
        FeatureSection(title: "Personal report", badge: "AI interpretation") {
            Text(report.provider.title).font(.headline)
            Text(report.model).font(.caption.monospaced()).foregroundStyle(Theme.text2)
            Text(report.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Theme.text2)
            Text(report.source).font(.subheadline).foregroundStyle(Theme.text2)
            ForEach(report.facts.filter { ["health.recent", "pod.coverage"].contains($0.id) }) { fact in
                VStack(alignment: .leading, spacing: 6) {
                    Label(ReportEvidenceLabel.title(fact.id), systemImage: "chart.bar.xaxis").font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.reportAccent)
                    Text(fact.text).font(.subheadline)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(Theme.reportAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            ReportDocumentView(document: ReportDocument(text: report.text, facts: report.facts), facts: report.facts)
            Text("AI interpretation · review before changing your routine. It cannot diagnose a condition or operate the bed.")
                .font(.caption).foregroundStyle(Theme.text2)
            DisclosureGroup("Calculated evidence used for this report") {
                ForEach(report.facts) { fact in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ReportEvidenceLabel.title(fact.id)).font(.caption.weight(.semibold)).foregroundStyle(Theme.reportAccent)
                        Text(fact.text).font(.subheadline)
                    }.padding(.vertical, 4)
                }
            }
            DisclosureGroup("Original response") {
                Text(report.text).font(.body).textSelection(.enabled)
            }.accessibilityIdentifier("report.original")
            if let input = report.inputTokens, let output = report.outputTokens {
                Text("Provider-reported usage: \(input) input · \(output) output tokens").font(.caption).foregroundStyle(Theme.text2)
            }
        }
    }
}
