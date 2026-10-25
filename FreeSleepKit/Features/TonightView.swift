import SwiftUI

struct TonightView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        SleepPage(title: "Tonight", subtitle: "Your bed, your rhythm.",
            badge: model.demo ? "Demo" : model.connected ? "Pod connected" : "Pod unavailable", badgeTone: model.connected && !model.demo ? .success : .neutral, badgeDot: true) {
            PodNotifications()
            if let message = model.message { Text(message).sleepText(.body).foregroundStyle(SleepTheme.secondary) }
            TonightBedCard()
            SidePicker().frame(maxWidth: 350)
            AlarmCard(side: model.side).id("\(model.side.rawValue):\(model.settings?.id ?? "demo")")
            if let message = model.actionMessage { Label(message, systemImage: "exclamationmark.circle").foregroundStyle(SleepTheme.error) }
            Button("Comfort learning and automations", systemImage: "sparkles") { model.tab = .autopilot }
                .buttonStyle(SleepButtonStyle(fill: true))
            SleepCard(title: "A glance at last night", eyebrow: "YOUR ROUTINE", actionTitle: "Explore sleep →", action: { model.tab = .sleep }) {
                let night = model.analytics?.nights.last
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) { metrics(night) }
                    VStack(alignment: .leading, spacing: 20) { metrics(night) }
                }
                Text("Based on Pod presence and vitals. Presence is not measured sleep.").sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            }
        }.refreshable { await model.refresh() }
    }
    @ViewBuilder private func metrics(_ night: SleepAnalytics.Night?) -> some View {
        metric("Bed presence", SleepAnalytics.duration(night?.occupiedMinutes))
        metric("Heart rate", night?.heartRate.map { "\($0.formatted(.number.precision(.fractionLength(1)))) bpm" } ?? "—")
        metric("Bed exits", night.map { String($0.exits) } ?? "—")
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(label).sleepText(.caption).foregroundStyle(SleepTheme.secondary); Text(value).sleepText(.smallMetric) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
