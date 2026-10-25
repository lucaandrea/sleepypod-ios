import SwiftUI

struct EpisodeReadings: View {
    let detail: EpisodeDetail
    @State private var page = 0
    private var count: Int { max(1, Int(ceil(Double(detail.samples.count) / 20))) }
    var body: some View {
        Text("Original recorded values, including those excluded from charts. HR in bpm; HRV in ms; breathing per minute. Missing readings are not zero.")
            .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow { Text("Pod local time"); Text("HR"); Text("HRV"); Text("Breathing"); Text("Presence") }
                    .fontWeight(.semibold)
                ForEach(Array(detail.samples.dropFirst(page * 20).prefix(20).enumerated()), id: \.offset) { _, sample in
                    GridRow {
                        Text(EpisodeDetail.clock(Date(timeIntervalSince1970: sample.at), timeZone: detail.timeZone, format: "MM/dd HH:mm:ss z"))
                        Text(EpisodeDetail.number(sample.heartRate)); Text(EpisodeDetail.number(sample.hrv)); Text(EpisodeDetail.number(sample.respiratoryRate))
                        Text(sample.present == nil ? "Unknown" : sample.present == true ? "Detected" : "Outside")
                    }.accessibilityElement(children: .combine)
                }
            }.sleepText(.small).monospacedDigit().padding(.vertical, 4)
        }.accessibilityLabel("Recorded vital readings")
        if detail.samples.isEmpty { Text("No readings were recorded in this episode.") }
        HStack {
            Button("Previous") { page -= 1 }.disabled(page == 0)
            Spacer(); Text("\(page + 1) / \(count)").sleepText(.caption); Spacer()
            Button("Next") { page += 1 }.disabled(page + 1 >= count)
        }
    }
}
