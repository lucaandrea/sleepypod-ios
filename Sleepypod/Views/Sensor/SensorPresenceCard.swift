import SwiftUI

struct SensorPresenceCard: View {
    @Environment(SensorStreamService.self) private var sensor
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 14) {
                Label("BED PRESENCE", systemImage: "person.fill.viewfinder").font(.caption.weight(.semibold)).foregroundStyle(Theme.text2)
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18)) : AnyLayout(HStackLayout(alignment: .top, spacing: 18))
                layout {
                    ForEach(Side.allCases) { side in
                        let reading = sensor.reportedPresence(side: side, now: .now)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(settings.sideName(for: side)).font(.headline)
                            Label(reading?.label ?? "Unknown", systemImage: reading?.occupied == true ? "person.fill" : "bed.double")
                                .foregroundStyle(reading?.occupied == true ? Theme.green : Theme.text2)
                                .accessibilityIdentifier("sensors.presence.\(side.rawValue)")
                            Text(reading?.detail ?? "Waiting for controller occupancy").font(.caption).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                            if SensorObservation.fresh(sensor.presenceUpdatedAt, age: 30, now: .now) {
                                let values = side == .left ? sensor.leftVariance : sensor.rightVariance
                                ForEach(0..<min(3, (values.count + 1) / 2), id: \.self) { zone in
                                    let activity = max(values[safe: zone * 2] ?? 0, values[safe: zone * 2 + 1] ?? 0)
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Channel \(zone + 1)").font(.caption)
                                            Spacer(minLength: 4)
                                            Text(activity, format: .number.precision(.fractionLength(2))).font(.caption.monospacedDigit())
                                        }
                                        ProgressView(value: min(1, Double(activity) / 0.5)).tint(side == .left ? Theme.cooling : Theme.warming)
                                    }.accessibilityElement(children: .combine)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text("Presence is reported by the controller. Channel activity visualizes capacitance variation; it does not determine occupancy.").font(.caption).foregroundStyle(Theme.text2)
                if let error = sensor.occupancyError { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
            }.cardStyle()
        }
    }
}
