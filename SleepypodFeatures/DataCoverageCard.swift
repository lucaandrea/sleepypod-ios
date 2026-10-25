import SwiftUI

struct DataCoverageCard: View {
    let report: DataCoverage?
    let timeZone: String
    var body: some View {
        FeatureSection(title: "Understand the data", eyebrow: "BEHIND THE NUMBERS") {
            if let report {
                FeatureStatus(title: report.comparisonAvailable ? "Weekly comparison available" : "Weekly comparison unavailable",
                           tone: report.comparisonAvailable ? .success : .neutral)
                Text(report.comparisonReason)
                if let recent = report.recent, let previous = report.previous {
                    Text("Periods end on the latest returned wake date · \(timeZone)").font(.caption).foregroundStyle(Theme.text2)
                    CoverageWindow(title: "Recent period", window: recent)
                    CoverageWindow(title: "Previous period", window: previous)
                } else {
                    Text("No recorded nights were returned for this range.")
                }
                if report.excludedEpisodes > 0 {
                    Text("\(report.excludedEpisodes) episode(s) with invalid times or windows over 72 hours were excluded.").foregroundStyle(Theme.amber)
                }
                Text(report.scopeNote).font(.caption).foregroundStyle(Theme.text2)
                Text("Counts describe returned records, not sensor uptime. Bed presence is not measured sleep.").font(.caption).foregroundStyle(Theme.text2)
            } else {
                Text("Update your sleepypod server to see coverage details.").foregroundStyle(Theme.text2)
            }
        }
    }
}

private struct CoverageWindow: View {
    let title: String
    let window: DataCoverage.Window
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text("\(window.from) → \(window.through)").font(.caption).foregroundStyle(Theme.text2)
            Text("\(window.presenceNights) of 7 dates with known presence")
            Text("\(window.recordedNights) recorded · \(window.heartRateNights) with heart rate · \(window.hrvNights) with HRV · \(window.respiratoryRateNights) with breathing")
                .font(.subheadline).foregroundStyle(Theme.text2)
            DisclosureGroup("Review the dates") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(window.days) { day in
                        ViewThatFits(in: .horizontal) {
                            HStack { Text(day.date); Spacer(minLength: 12); state(day) }
                            VStack(alignment: .leading, spacing: 4) { Text(day.date); state(day) }
                        }.font(.subheadline)
                    }
                }.padding(.top, 12)
            }.tint(Theme.text1)
        }
    }
    private func state(_ day: DataCoverage.Day) -> some View {
        Text(day.label).foregroundStyle(day.status == "known" ? Theme.text2 : Theme.amber)
    }
}
