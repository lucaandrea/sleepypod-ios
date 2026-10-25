import SwiftUI

struct PersonalReportCard: View {
    let report: PersonalSleepReport
    var body: some View {
        SleepCard(title: "Your sleep perspective", eyebrow: report.model) {
            Text(report.createdAt.formatted(date: .abbreviated, time: .shortened)).sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            Text(report.text).textSelection(.enabled).sleepText(.body)
            Text("AI interpretation · review before changing your routine. It cannot diagnose a condition or operate the bed.")
                .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            DisclosureGroup("Calculated evidence used for this report") {
                ForEach(report.facts) { fact in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fact.id).sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                        Text(fact.text).sleepText(.small)
                    }.padding(.vertical, 4)
                }
            }
            if let input = report.inputTokens, let output = report.outputTokens {
                Text("Provider-reported usage: \(input) input · \(output) output tokens").sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            }
        }
    }
}
