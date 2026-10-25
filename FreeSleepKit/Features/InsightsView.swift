import SwiftUI

struct InsightsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        @Bindable var model = model
        SleepPage(title: "Understand your nights.", subtitle: "Notice your patterns. Find a rhythm that feels like you.", badge: "Local analytics", badgeTone: .success) {
            SidePicker()
            SleepSegmentedPicker(title: "History range", options: [7, 30, 90], selection: $model.days) { "\($0) days" }
            if let error = model.analyticsError {
                Text(error).foregroundStyle(SleepTheme.error)
                Button("Retry") { Task { await model.refresh() } }.buttonStyle(SleepButtonStyle())
            }
            let summary = model.analytics?.summary
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 16) {
                metric("Bed presence", SleepAnalytics.duration(summary?.averageOccupiedMinutes), "Recent recorded nights")
                metric("Bedtime variation", summary?.bedtimeVariationMinutes.map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) min" } ?? "—", "Lower means more consistent")
                metric("Heart rate", summary?.averageHeartRate.map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) bpm" } ?? "—", "During detected presence")
                metric("Recorded nights", summary.map { String($0.recordedNights) } ?? "—", "Missing nights are not zero")
            }
            if let analytics = model.analytics {
                DataCoverageCard(report: analytics.quality?.coverage, timeZone: analytics.timeZone).id("\(model.side.rawValue):\(model.days):coverage")
            }
            SleepCard(title: "Time made for rest", eyebrow: "BED PRESENCE") {
                if let nights = model.analytics?.nights, !nights.isEmpty {
                    PresenceChart(nights: nights)
                    Text("Longest episode per wake date · \(model.analytics?.timeZone ?? "Pod timezone")").sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                } else {
                    Text(model.connected ? "No nights recorded yet. Enable biometrics on your Pod to start building your history." : "Connect to your Pod to see your recorded nights.")
                        .foregroundStyle(SleepTheme.secondary)
                }
            }
            EpisodeBrowser(episodes: model.analytics?.episodes ?? model.analytics?.nights ?? [], timeZone: model.analytics?.timeZone ?? "UTC")
                .id("\(model.side.rawValue):\(model.days)")
            JournalCard().id(model.side)
            SleepCard(title: "Beyond the headline") {
                Text("HRV estimate: \(summary?.averageHrv.map { String(Int($0)) } ?? "—") ms")
                Text("Breathing estimate: \(summary?.averageRespiratoryRate.map { String(Int($0)) } ?? "—") / min")
                Text("These estimates are experimental. Bed presence does not establish sleep stages or sleep quality.")
                    .sleepText(.body).foregroundStyle(SleepTheme.secondary)
            }
        }.refreshable { await model.refresh() }
    }
    private func metric(_ title: String, _ value: String, _ caption: String) -> some View {
        SleepCard(title: title) { VStack(alignment: .leading, spacing: 0) { Text(value).sleepText(.metric); Text(caption).sleepText(.caption).foregroundStyle(SleepTheme.secondary) } }
    }
}
