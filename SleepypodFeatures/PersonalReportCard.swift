import SwiftUI

struct PersonalReportCard: View {
    let report: PersonalSleepReport
    var body: some View {
        FeatureSection(title: "Personal report", eyebrow: report.model) {
            Text(report.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Theme.text2)
            Text(report.text).textSelection(.enabled).font(.body)
            Text("AI interpretation · review before changing your routine. It cannot diagnose a condition or operate the bed.")
                .font(.caption).foregroundStyle(Theme.text2)
            DisclosureGroup("Calculated evidence used for this report") {
                ForEach(report.facts) { fact in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fact.id).font(.caption).foregroundStyle(Theme.text2)
                        Text(fact.text).font(.subheadline)
                    }.padding(.vertical, 4)
                }
            }
            if let input = report.inputTokens, let output = report.outputTokens {
                Text("Provider-reported usage: \(input) input · \(output) output tokens").font(.caption).foregroundStyle(Theme.text2)
            }
        }
    }
}
