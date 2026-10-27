import SwiftUI

struct BedroomDevicesCard: View {
    @Environment(BedroomSession.self) private var session
    @Environment(SettingsManager.self) private var settings
    var compact = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            // A new response can arrive after the last scheduled timeline tick.
            let date = Date.now
            VStack(alignment: .leading, spacing: 16) {
                if session.isSyntheticExample { Eyebrow("SYNTHETIC EXAMPLE", color: Theme.amber) }
                Label(session.workspace?.status?.config.roomName ?? "Bedroom devices", systemImage: "house").font(.headline)
                if let model = session.workspace, let status = model.status {
                    if status.config.sources.isEmpty {
                        Text("No bedroom devices connected yet. Add your room sensors to see their readings here.").foregroundStyle(Theme.text2)
                    } else {
                        let sources = status.config.sources.filter { !compact || [.temperature, .humidity, .pm25, .co2, .airQuality].contains($0.metric) }
                        let identifiers = sources.map(\.deviceId).reduce(into: [String]()) { result, identifier in
                            if !result.contains(identifier) { result.append(identifier) }
                        }
                        ForEach(identifiers, id: \.self) { identifier in
                            BedroomDeviceReadings(model: model, deviceID: identifier, date: date, celsius: settings.temperatureFormat == .celsius, compact: compact)
                        }
                        if !compact {
                            Divider()
                            Text("Room comfort inputs").font(.subheadline)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 24) { climate(model, at: date) }
                                VStack(alignment: .leading, spacing: 12) { climate(model, at: date) }
                            }
                            Text(model.guidance(at: date)?.reason ?? "Autopilot needs fresh, selected temperature and humidity readings. Last-reported values are display only.")
                                .font(.footnote).foregroundStyle(Theme.text2)
                        }
                        if !status.config.enabled { Text("Bedroom context is disabled.").font(.footnote).foregroundStyle(Theme.amber) }
                    }
                    if model.serverTime(at: date) == nil { Text("Current readings need a refresh.").font(.caption).foregroundStyle(Theme.amber) }
                } else { Text("Connect to an updated Sleepypod Core controller to see bedroom devices.").foregroundStyle(Theme.text2) }
                if let error = session.workspace?.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                Text("Room-aware comfort must be selected in Autopilot. Saved wake-up times and manual pauses keep priority.").font(.caption).foregroundStyle(Theme.text2)
                if compact { NavigationLink("Bedroom devices and readings") { BedroomDevicesScreen() } }
            }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                .accessibilityElement(children: .contain).accessibilityIdentifier("bedroom.summary")
        }
    }
    @ViewBuilder private func climate(_ model: BedroomWorkspace, at date: Date) -> some View {
        ForEach([BedroomMetric.temperature, .humidity], id: \.rawValue) { metric in
            VStack(alignment: .leading, spacing: 4) {
                Text(metric.title).font(.caption).foregroundStyle(Theme.text2)
                Text(BedroomDeviceReadings.formatted(model.aggregate(metric, at: date), metric: metric, celsius: settings.temperatureFormat == .celsius))
                    .font(.title2.monospacedDigit()).accessibilityIdentifier("bedroom.climate.\(metric.rawValue)")
            }.accessibilityElement(children: .combine)
        }
    }
}
