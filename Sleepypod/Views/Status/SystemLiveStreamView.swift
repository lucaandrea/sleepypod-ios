import SwiftUI

struct SystemLiveStreamView: View {
    @Environment(SensorStreamService.self) private var sensor
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Live stream").font(.headline)
            Text(sensor.isConnected ? "Receiving from the controller connection" : "Stream disconnected").font(.footnote).foregroundStyle(sensor.isConnected ? Theme.green : Theme.amber)
            if let error = sensor.error { Text(error).foregroundStyle(Theme.amber) }
            Text("Arrivals seen by this app in the last 60 seconds. Counts are capped at the newest 1,200 frames.").font(.caption).foregroundStyle(Theme.text2)
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                ForEach(SensorStreamActivity.groups) { group in stream(group, at: timeline.date) }
            }
            NavigationLink("Inspect raw frames") {
                ScrollView {
                    FirmwareLogConsoleView(logs: sensor.firmwareLogs, recentFrames: sensor.recentFrames, onClear: { sensor.clearLogs() }).padding(16)
                }.background(Theme.background).navigationTitle("Raw frames")
            }.accessibilityIdentifier("health.rawFrames")
        }
    }
    private func stream(_ group: SensorStreamActivity.Group, at now: Date) -> some View {
        let ticks = sensor.streamActivity.recent(group, at: now)
        let latest = sensor.streamActivity.last[group.id]
        return VStack(alignment: .leading, spacing: 6) {
            Label { Text(group.title) } icon: { Circle().fill(ticks.isEmpty ? Theme.text3 : Theme.green).frame(width: 8, height: 8) }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.active)
                    ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                        Rectangle().fill(Theme.text1).frame(width: 2, height: 10)
                            .offset(x: max(0, geometry.size.width - 2) * (1 - now.timeIntervalSince(tick.time) / 60))
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 3))
            }.frame(height: 18).accessibilityHidden(true)
            Text("\(ticks.count) in the last minute · \(latest.map { "last \(max(0, Int(now.timeIntervalSince($0.time))))s ago · \($0.type)" } ?? "not received")")
                .font(.caption.monospacedDigit()).foregroundStyle(Theme.text2)
        }
    }
}
