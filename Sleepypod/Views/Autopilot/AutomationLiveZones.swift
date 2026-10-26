import SwiftUI

struct AutomationZoneBars: View {
    let values: [Double]
    let scale: Double
    let peak: Int?
    var body: some View {
        ForEach(values.indices, id: \.self) { index in
            let value = values[index]
            let intensity = value.isFinite ? min(1, max(0, value / max(0.01, scale))) : 0
            HStack {
                Text(values.count == 3 ? ["Head", "Torso", "Legs"][index] : "Zone \(index + 1)")
                Spacer(minLength: 10)
                Text(value.isFinite ? value.formatted(.number.precision(.fractionLength(2))) : "Missing").monospacedDigit()
            }.font(.subheadline).padding(14).frame(maxWidth: .infinity)
                .background(Theme.cool.opacity(0.08 + intensity * 0.5), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(peak == index && value > 0 ? Theme.cool : Theme.border1, lineWidth: 1))
                .accessibilityElement(children: .combine)
        }
    }
}

struct AutomationLiveZones: View {
    @Environment(SensorStreamService.self) private var sensors
    @Environment(SettingsManager.self) private var settings
    let side: Side?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let fresh = sensors.isConnected && sensors.isCurrentPod && sensors.presenceUpdatedAt.map { context.date.timeIntervalSince($0) < 10 } == true
            VStack(alignment: .leading, spacing: 12) {
                Text("Live contact activity").font(.headline)
                if APIBackend.current.isDemo { Text("Synthetic Demo sensor readings").font(.caption).foregroundStyle(Theme.amber) }
                ForEach(side.map { [$0] } ?? Side.allCases) { selected in
                    Text(settings.sideName(for: selected)).font(.subheadline.weight(.semibold))
                    let raw = selected == .left ? sensors.leftPresence?.values : sensors.rightPresence?.values
                    if fresh, let raw, raw.count >= 6 {
                        let variance = selected == .left ? sensors.leftVariance : sensors.rightVariance
                        let values = AutomationZoneReplay.liveZones(variance)
                        AutomationZoneBars(values: values, scale: 0.5, peak: values.max().flatMap { $0 > 0.02 ? values.firstIndex(of: $0) : nil })
                    } else { Text("Waiting for fresh spatial contact readings.").foregroundStyle(Theme.text2) }
                }
                Text("Activity compares variation in paired capacitive channels over 20 readings. It is not temperature or calibrated body pressure. Brighter means more activity; the outline marks the most active zone.").font(.footnote).foregroundStyle(Theme.text2)
            }
        }.task { sensors.connect() }
    }
}
