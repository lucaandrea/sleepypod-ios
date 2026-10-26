import SwiftUI

/// Temperature regions and capacitance channel pairs use separate layers: their geometry is not interchangeable.
struct BedMatrixView: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dynamicTypeSize) private var typeSize
    let leftPresence: CapSenseSide?
    let rightPresence: CapSenseSide?
    let leftVariance: [Float]
    let rightVariance: [Float]
    let leftTemps: BedTempSide?
    let rightTemps: BedTempSide?
    @State private var temperature = true

    var body: some View {
        VStack(spacing: 12) {
            Menu {
                Picker("Matrix layer", selection: $temperature) { Text("Temperature").tag(true); Text("Capacitance").tag(false) }
            } label: {
                HStack {
                    Text(temperature ? "Temperature" : "Capacitance").fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }
            }.accessibilityIdentifier("sensors.matrixLayer")
            ForEach(0..<3, id: \.self) { index in
                VStack(alignment: .leading, spacing: 8) {
                    Text(temperature ? ["Outer", "Center", "Inner"][index] : "Channel pair \(index + 1)").font(.caption.weight(.semibold)).foregroundStyle(Theme.text2)
                    let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
                    layout { cell(.left, index: index); cell(.right, index: index) }
                }
            }
            Text(temperature ? "Six measured regions across the mattress. Head-to-foot detail is not measured." : "Raw paired channels and variation. Channel positions are schematic; activity is not an occupancy verdict.")
                .font(.caption).foregroundStyle(Theme.text2)
        }
    }
    private func cell(_ side: Side, index: Int) -> some View {
        let temps = side == .left ? leftTemps : rightTemps
        let presence = side == .left ? leftPresence : rightPresence
        let variance = side == .left ? leftVariance : rightVariance
        let celsius = temps?.temps[safe: index].flatMap { $0.isFinite && $0 > -100 ? Double($0) : nil }
        return VStack(alignment: .leading, spacing: 6) {
            Text(settings.sideName(for: side)).font(.caption).foregroundStyle(Theme.text2)
            if temperature {
                Text(celsius.map { String(format: "%.1f°%@", settings.temperatureFormat == .celsius ? $0 : $0 * 9 / 5 + 32, settings.temperatureFormat == .celsius ? "C" : "F") } ?? "—")
                    .font(.headline.monospacedDigit())
            } else {
                ForEach((index * 2)..<(index * 2 + 2), id: \.self) { channel in
                    let value = presence?.values[safe: channel].flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                    Text("\(channel + 1): \(value.map { String(format: "%.2f", $0) } ?? "—") · Δ \(value == nil ? "—" : variance[safe: channel].map { String(format: "%.2f", $0) } ?? "—")")
                        .font(.subheadline.monospacedDigit())
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(temperature ? TempRamp.color(celsius.map { $0 * 9 / 5 + 32 }).opacity(0.18) : Theme.active)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
