import SwiftUI

struct BedroomDeviceReadings: View {
    let model: BedroomWorkspace
    let deviceID: String
    let date: Date
    let celsius: Bool
    var compact = false
    private var observations: [BedroomObservation] { model.status?.observations.filter { $0.source.deviceId == deviceID } ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let source = observations.first?.source {
                Divider()
                Text(source.deviceName).font(.headline)
                if !compact { Text("\(source.provider.title) · \(source.location.title)").font(.caption).foregroundStyle(Theme.text2) }
            }
            ForEach(observations) { item in
                let current = model.value(item, at: date)
                let lastReported = current == nil ? model.lastReportedValue(item) : nil
                let value = current ?? lastReported
                VStack(alignment: .leading, spacing: 4) {
                    ViewThatFits(in: .horizontal) {
                        HStack { Text(item.source.label); Spacer(); Text(Self.formatted(value, metric: item.source.metric, celsius: celsius)).monospacedDigit() }
                        VStack(alignment: .leading) { Text(item.source.label); Text(Self.formatted(value, metric: item.source.metric, celsius: celsius)).monospacedDigit() }
                    }
                    Text(model.readingStatus(item, at: date)).font(.caption).foregroundStyle(current == nil ? Theme.text2 : Theme.text1)
                    if lastReported != nil { Text("Last reported value; not a live measurement.").font(.caption2).foregroundStyle(Theme.text2) }
                    if let measured = item.measuredAt {
                        Text("Measured \(HomeRoomSummaryCard.date(measured))").font(.caption2).foregroundStyle(Theme.text2)
                    } else if let reported = item.observedAt {
                        Text("Reported \(HomeRoomSummaryCard.date(reported))").font(.caption2).foregroundStyle(Theme.text2)
                    }
                    if item.source.provider == .appleHome && item.status == .waiting && !compact {
                        Text("Apple Home has not sent this sensor to Sleepypod. Pairing the HomePod for audio does not provide temperature or humidity.")
                            .font(.caption2).foregroundStyle(Theme.text2)
                    }
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
