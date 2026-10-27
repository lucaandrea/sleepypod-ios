import SwiftUI

struct BedroomDevicesCard: View {
    @Environment(BedroomSession.self) private var session
    @Environment(SettingsManager.self) private var settings
    var compact = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 16) {
                if session.isSyntheticExample { Eyebrow("SYNTHETIC EXAMPLE", color: Theme.amber) }
                Label(session.workspace?.status?.config.roomName ?? "Bedroom devices", systemImage: "house").font(.headline)
                if let model = session.workspace, let status = model.status {
                    if status.config.sources.isEmpty {
                        Text("No bedroom devices connected yet. Add your room sensors to see their readings here.").foregroundStyle(Theme.text2)
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 24) { climate(model, at: context.date) }
                            VStack(alignment: .leading, spacing: 12) { climate(model, at: context.date) }
                        }
                        Text(model.guidance(at: context.date)?.reason ?? "Fresh, selected temperature and humidity readings are required for bedroom-aware comfort.")
                            .font(.footnote).foregroundStyle(Theme.text2)
                        if !compact {
                            let identifiers = status.config.sources.map(\.deviceId).reduce(into: [String]()) { result, identifier in
                                if !result.contains(identifier) { result.append(identifier) }
                            }
                            ForEach(identifiers, id: \.self) { identifier in
                                BedroomDeviceReadings(model: model, deviceID: identifier, date: context.date, celsius: settings.temperatureFormat == .celsius)
                            }
                        }
                        if !status.config.enabled { Text("Bedroom context is disabled.").font(.footnote).foregroundStyle(Theme.amber) }
                    }
                    if model.serverTime(at: context.date) == nil { Text("Readings withheld · refresh required").font(.caption).foregroundStyle(Theme.amber) }
                } else { Text("Connect to an updated Sleepypod Core controller to see bedroom devices.").foregroundStyle(Theme.text2) }
                if let error = session.workspace?.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                Text("Room-aware comfort must be selected in Autopilot. Saved wake-up times and manual pauses keep priority.").font(.caption).foregroundStyle(Theme.text2)
                if compact { NavigationLink("Bedroom devices and readings") { BedroomDevicesScreen() } }
            }.frame(maxWidth: .infinity, alignment: .leading).cardStyle().accessibilityIdentifier("bedroom.summary")
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

struct BedroomDeviceReadings: View {
    let model: BedroomWorkspace
    let deviceID: String
    let date: Date
    let celsius: Bool
    private var observations: [BedroomObservation] { model.status?.observations.filter { $0.source.deviceId == deviceID } ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let source = observations.first?.source {
                Divider()
                Text(source.deviceName).font(.headline)
                Text("\(source.provider.title) · \(source.location.title)").font(.caption).foregroundStyle(Theme.text2)
            }
            ForEach(observations) { item in
                let value = model.value(item, at: date)
                VStack(alignment: .leading, spacing: 4) {
                    ViewThatFits(in: .horizontal) {
                        HStack { Text(item.source.label); Spacer(); Text(Self.formatted(value, metric: item.source.metric, celsius: celsius)).monospacedDigit() }
                        VStack(alignment: .leading) { Text(item.source.label); Text(Self.formatted(value, metric: item.source.metric, celsius: celsius)).monospacedDigit() }
                    }
                    Text(value == nil && item.status == .fresh ? "Waiting for a fresh update" : item.status.title).font(.caption).foregroundStyle(Theme.text2)
                    if let measured = item.measuredAt {
                        Text("Measured \(HomeRoomSummaryCard.date(measured))").font(.caption2).foregroundStyle(Theme.text2)
                    } else if let reported = item.observedAt {
                        Text("Reported \(HomeRoomSummaryCard.date(reported))").font(.caption2).foregroundStyle(Theme.text2)
                    }
                    if value != nil { Text(item.controlEligible ? "Selected for room context" : "Display only").font(.caption2).foregroundStyle(Theme.text2) }
                }.accessibilityElement(children: .combine).accessibilityIdentifier("bedroom.source.\(item.id)")
            }
        }
    }
    static func formatted(_ value: Double?, metric: BedroomMetric, celsius: Bool) -> String {
        guard let value else { return "—" }
        if metric == .power { return value == 1 ? "On" : "Off" }
        if metric == .airQuality { return [1: "Excellent", 2: "Good", 3: "Fair", 4: "Inferior", 5: "Poor"][Int(value)] ?? "Unknown" }
        let displayed = metric == .temperature && celsius ? (value - 32) * 5 / 9 : value
        let unit = metric == .temperature && celsius ? "°C" : metric.unit
        return "\(displayed.formatted(.number.precision(.fractionLength(0...1)))) \(unit)"
    }
}
