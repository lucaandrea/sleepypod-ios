import SwiftUI

struct TemperatureCard: View {
    @Environment(AppModel.self) private var model
    @State private var target = 80.0
    @State private var edited = false
    @ScaledMetric(relativeTo: .largeTitle) private var temperatureSize = SleepTokens.Typography.temperature
    @ScaledMetric(relativeTo: .title) private var unitSize = SleepTokens.Typography.temperatureUnit
    var body: some View {
        let status = model.device?[model.side]
        let unavailable = status == nil || model.settings?[model.side].awayMode == true
        SleepCard(title: "Your side of comfort", eyebrow: "TEMPERATURE", badge: unavailable ? "Offline" : status?.isOn == true ? "On" : "Off",
            badgeTone: !unavailable && status?.isOn == true ? .success : .neutral) {
            VStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(unavailable ? "—" : model.temperatureLabel(edited ? target : status!.targetTemperatureF))
                        .font(.system(size: temperatureSize, weight: .medium)).tracking(-0.07 * temperatureSize).lineLimit(1).minimumScaleFactor(0.5)
                    Text(model.settings?.temperatureFormat == "celsius" ? "°C" : "°F").font(.system(size: unitSize)).foregroundStyle(SleepTheme.secondary)
                }
                Text(status.map { "Target · currently \(model.temperatureLabel($0.currentTemperatureF))°" } ?? "Connect your Pod to set a temperature")
                    .sleepText(.body).foregroundStyle(SleepTheme.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 16)
            SleepSlider(title: "Target bed temperature", value: $target, range: 55...110)
                .onChange(of: target) { if target != status?.targetTemperatureF { edited = true } }
                .disabled(status == nil || model.acting || model.settings?[model.side].awayMode == true)
            HStack { Text("Cool · \(model.temperatureLabel(55))°"); Spacer(); Text("Warm · \(model.temperatureLabel(110))°") }.sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            HStack {
                Button(status?.isOn == true ? "Turn off" : "Turn on", systemImage: "power") {
                    Task { await model.setPower(!(status?.isOn ?? false)) }
                }.buttonStyle(SleepButtonStyle())
                Button("Set temperature") { Task { await model.setTemperature(target); if model.actionMessage == nil { edited = false } } }
                    .buttonStyle(SleepButtonStyle(kind: .primary, fill: true)).disabled(!edited)
            }.controlSize(.large).disabled(status == nil || model.acting || model.settings?[model.side].awayMode == true)
        }
        .onAppear { target = status?.targetTemperatureF ?? 80; edited = false }
        .onChange(of: status?.targetTemperatureF) {
            if !edited { target = status?.targetTemperatureF ?? 80; edited = false }
        }
    }
}
