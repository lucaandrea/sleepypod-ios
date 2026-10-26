import SwiftUI

struct SensorFreezerCard: View {
    @Environment(SensorStreamService.self) private var sensor
    @Environment(SettingsManager.self) private var settings
    let model: SensorDiagnosticsWorkspace
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 14) {
                Label("FREEZER", systemImage: "snowflake").font(.caption.weight(.semibold)).foregroundStyle(Theme.text2)
                let live = sensor.frzTemperature?.reading
                let reading = [live, model.freezer].compactMap { $0 }.filter { $0.date.map { $0 <= .now } ?? false }.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
                if let reading {
                    Text("\(live?.timestamp == reading.timestamp ? "Stream" : "Stored") temperatures · \(age(reading.date, now: .now))")
                        .font(.caption).foregroundStyle(SensorObservation.fresh(reading.date, now: .now) ? Theme.text2 : Theme.amber)
                    value("Heatsink", temperature(reading.heatsinkTemp))
                    value("Hub ambient", temperature(reading.ambientTemp))
                    value("Water · \(settings.leftName)", temperature(reading.leftWaterTemp))
                    value("Water · \(settings.rightName)", temperature(reading.rightWaterTemp))
                } else { Text("No freezer temperature readings").font(.footnote).foregroundStyle(Theme.text2) }
                Divider()
                let health = sensor.frzHealth
                let healthDate = health.map { Date(timeIntervalSince1970: Double($0.ts)) }
                Text("Pump and fan observations · \(age(healthDate, now: .now))")
                    .font(.caption).foregroundStyle(SensorObservation.fresh(healthDate, now: .now) ? Theme.text2 : Theme.amber)
                ForEach(Side.allCases) { side in
                    let observed = side == .left ? health?.left : health?.right
                    value("\(settings.sideName(for: side)) pump", observed?.pump?.rpm.map { "\($0) rpm" } ?? "—")
                    value("\(settings.sideName(for: side)) TEC", observed?.tec?.current.map { String(format: "%.1f A", $0) } ?? "—")
                    value("\(settings.sideName(for: side)) flow", number(observed?.temps?.flowrate))
                }
                value("Top fan", health?.fan?.top?.rpm.map { "\($0) rpm" } ?? "—")
                value("Bottom fan", health?.fan?.bottom?.rpm.map { "\($0) rpm" } ?? "—")
                if let control = sensor.frzThermal {
                    Text("Thermal output · \(age(Date(timeIntervalSince1970: Double(control.ts)), now: .now))").font(.caption).foregroundStyle(Theme.text2)
                    value("Left / right", "\(number(control.left?.power)) / \(number(control.right?.power))")
                    ForEach(Side.allCases) { side in
                        let state = side == .left ? control.left : control.right
                        value("\(settings.sideName(for: side)) control", state?.valid == false ? "Invalid" : state?.enabled == false ? "Disabled" : state?.enabled == true ? "Enabled" : "Not reported")
                    }
                }
                let waterDate = model.water?.timestamp.flatMap(SensorObservation.date)
                let waterFresh = model.fresh("Water", now: .now) && SensorObservation.fresh(waterDate, now: .now)
                value("Tank level", waterFresh ? (model.water?.level == "ok" ? "Normal" : model.water?.level == "low" ? "Low" : "Unknown") : "Unknown")
                Text("Flow is the firmware diagnostic value; no volume unit is inferred. Missing observations stay blank.").font(.caption).foregroundStyle(Theme.text2)
            }.cardStyle()
        }
    }
    private func temperature(_ celsius: Double?) -> String {
        guard let celsius = SensorObservation.finite(celsius) else { return "—" }
        let useCelsius = settings.temperatureFormat == .celsius
        return String(format: "%.1f°%@", useCelsius ? celsius : celsius * 9 / 5 + 32, useCelsius ? "C" : "F")
    }
    private func number(_ value: Double?) -> String { SensorObservation.finite(value).map { String(format: "%.2f", $0) } ?? "—" }
    private func age(_ date: Date?, now: Date) -> String {
        guard let date, date <= now else { return "measurement time unavailable" }
        let seconds = Int(now.timeIntervalSince(date))
        return "\(seconds < 120 ? "\(seconds)s" : "\(seconds / 60)m") old\(seconds > 90 ? " · stale" : "")"
    }
    private func value(_ title: String, _ value: String) -> some View {
        SensorDiagnosticValue(title: title, value: value)
    }
}
