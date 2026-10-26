import SwiftUI

struct SensorHistoryCards: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    let model: SensorDiagnosticsWorkspace
    @State private var hours = 6
    private var unit: String { settings.temperatureFormat == .celsius ? "°C" : "°F" }
    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                Text("BED TEMPERATURE").font(.caption.weight(.semibold)).foregroundStyle(Theme.text2)
                Picker("Temperature history range", selection: $hours) {
                    ForEach([1, 6, 12, 24], id: \.self) { Text("\($0) hours").tag($0) }
                }.pickerStyle(.menu).accessibilityIdentifier("sensors.historyRange")
                if model.loading.contains("History") && model.history.isEmpty { ProgressView("Reading temperature history…") }
                SensorTrendChart(points: model.temperaturePoints.map { $0.temperature(fahrenheit: settings.temperatureFormat != .celsius) }, unit: unit).equatable()
                if let summary = model.summary?.bedTemp {
                    SensorDiagnosticValue(title: "Average left", value: temperature(summary.avgLeftCenterTemp))
                    SensorDiagnosticValue(title: "Average right", value: temperature(summary.avgRightCenterTemp))
                    SensorDiagnosticValue(title: "Ambient average", value: temperature(summary.avgAmbientTemp))
                    SensorDiagnosticValue(title: "Ambient range", value: "\(temperature(summary.minAmbientTemp)) – \(temperature(summary.maxAmbientTemp))")
                    Text("Summary of \(summary.recordCount) stored readings").font(.caption).foregroundStyle(Theme.text2)
                }
                if let error = model.errors["History"] ?? model.errors["Summary"] { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
            }.cardStyle()
            VStack(alignment: .leading, spacing: 14) {
                Text("HUMIDITY · \(hours)H").font(.caption.weight(.semibold)).foregroundStyle(Theme.text2)
                SensorTrendChart(points: model.humidityPoints, unit: "%").equatable()
                if let humidity = SensorObservation.finite(model.summary?.bedTemp?.avgHumidity) {
                    SensorDiagnosticValue(title: "Average humidity", value: String(format: "%.1f%%", humidity))
                }
                Text("Missing samples and long gaps remain disconnected.").font(.caption).foregroundStyle(Theme.text2)
            }.cardStyle()
        }
        .task(id: "\(hours)-\(scenePhase)") {
            guard scenePhase == .active else { return }
            repeat {
                await model.refreshHistory(hours: hours)
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            } while !Task.isCancelled
        }
    }
    private func converted(_ value: Double?) -> Double? {
        SensorObservation.finite(value).map { settings.temperatureFormat == .celsius ? $0 : $0 * 9 / 5 + 32 }
    }
    private func temperature(_ value: Double?) -> String { converted(value).map { String(format: "%.1f%@", $0, unit) } ?? "—" }
}

struct SensorFlowCard: View {
    @Environment(SensorStreamService.self) private var sensor
    @Environment(SettingsManager.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    let model: SensorDiagnosticsWorkspace
    @State private var hours = 6
    @State private var rpm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(rpm ? "PUMP SPEED" : "FLOW DIAGNOSTIC").font(.caption.weight(.semibold)).foregroundStyle(Theme.text2)
            Picker("Flow view", selection: $rpm) { Text("Flow").tag(false); Text("RPM").tag(true) }
                .pickerStyle(.segmented).accessibilityIdentifier("sensors.flowMode")
            Picker("Flow history range", selection: $hours) {
                ForEach([1, 6, 24, 72, 168], id: \.self) { Text($0 < 24 ? "\($0) hours" : "\($0 / 24) days").tag($0) }
            }.pickerStyle(.menu).accessibilityIdentifier("sensors.flowRange")
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let health = sensor.frzHealth
                let fresh = SensorObservation.fresh(health.map { Date(timeIntervalSince1970: Double($0.ts)) }, now: .now)
                ForEach(Side.allCases) { side in
                    let data = side == .left ? health?.left : health?.right
                    let value = rpm ? data?.pump?.rpm.map(Double.init) : data?.temps?.flowrate
                    SensorDiagnosticValue(title: settings.sideName(for: side), value: fresh ? value.map { String(format: rpm ? "%.0f rpm" : "%.2f", $0) } ?? "—" : "—")
                }
                Text(fresh ? "Latest stream values" : "Live readings unavailable or stale").font(.caption).foregroundStyle(fresh ? Theme.text2 : Theme.amber)
            }
            if model.loading.contains("Flow") && model.flow.isEmpty { ProgressView("Reading flow history…") }
            SensorTrendChart(points: rpm ? model.rpmPoints : model.flowPoints, unit: rpm ? "rpm" : "Flow").equatable()
            if let error = model.errors["Flow"] { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
        }.cardStyle()
            .task(id: "\(hours)-\(scenePhase)") {
                guard scenePhase == .active else { return }
                repeat {
                    await model.refreshFlow(hours: hours)
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                } while !Task.isCancelled
            }
    }
}

struct SensorDiagnosticValue: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let value: String
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(Theme.text2)
                    Text(value).monospacedDigit().foregroundStyle(Theme.text1)
                }.accessibilityElement(children: .combine)
            } else {
                LabeledContent(title) { Text(value).monospacedDigit().foregroundStyle(Theme.text1) }
            }
        }.font(.subheadline).fixedSize(horizontal: false, vertical: true)
    }
}
