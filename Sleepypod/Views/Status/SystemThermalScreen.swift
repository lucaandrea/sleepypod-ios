import SwiftUI

struct SystemThermalScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SettingsManager.self) private var settings
    @State private var model: SystemThermalWorkspace
    init(client: (any SystemThermalClient)? = nil) {
        _model = State(initialValue: .init(client: client ?? (APIBackend.current.isDemo ? DemoSystemThermalClient() : CoreSystemThermalClient())))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if APIBackend.current.isDemo { Text("DEMO · simulated thermal readings").font(.footnote).foregroundStyle(Theme.amber) }
                Picker("History", selection: Binding(get: { model.range }, set: { model.setRange($0) })) {
                    ForEach(ThermalRange.allCases) { range in Text(range.title).tag(range) }
                }.accessibilityIdentifier("thermal.range")
                if let error = model.snapshotError { Text("Current readings: \(error). Any retained readings may be stale.").foregroundStyle(Theme.amber) }
                if let error = model.historyError, model.range != .live { Text("History: \(error). Any retained history may be stale.").foregroundStyle(Theme.amber) }
                if let snapshot = model.snapshot {
                    if snapshot.reportsPumpSpeed != false && !snapshot.pumpStallProtectionEnabled {
                        Label("Pump-stall protection is off", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.amber)
                    }
                    Text("Heatsink \(temperature(snapshot.heatsinkTempF)) · hub ambient \(temperature(snapshot.ambientTempF))").font(.footnote.monospacedDigit()).foregroundStyle(Theme.text2)
                }
                NavigationLink("Pump protection settings") { PumpProtectionSettingsScreen() }.accessibilityIdentifier("thermal.protection")
                if let chart = model.chart { SystemThermalCharts(data: chart).id(model.range) }
                else if model.range == .live { Text("Collecting live samples… Updates every five seconds while this screen is open.").font(.footnote).foregroundStyle(Theme.text2) }
                else if model.loadingHistory { ProgressView("Reading thermal history…") }
                else { Text("No thermal history is available.").foregroundStyle(Theme.text2) }
                if let snapshot = model.snapshot { ForEach(snapshot.sides) { side in sideCard(side) } }
                if let received = model.snapshotReceivedAt { Text("Current readings received \(received.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(Theme.text2) }
                Button("Refresh thermal readings") { Task { await model.refreshSnapshot(); await model.refreshHistory() } }
                    .disabled(model.loadingSnapshot || model.loadingHistory)
            }.padding(16)
        }.accessibilityIdentifier("thermal.content").background(Theme.background).navigationTitle("Thermal").navigationBarTitleDisplayMode(.inline)
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                repeat {
                    await model.refreshSnapshot()
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                } while !Task.isCancelled
            }
            .task(id: "\(model.range.rawValue)-\(scenePhase == .active)") {
                guard scenePhase == .active, model.range != .live else { return }
                repeat {
                    await model.refreshHistory()
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                } while !Task.isCancelled
            }
    }
    private func temperature(_ value: Double?) -> String {
        guard let value else { return "Unknown" }
        let celsius = settings.temperatureFormat == .celsius
        return "\((celsius ? (value - 32) * 5 / 9 : value).formatted(.number.precision(.fractionLength(1))))\(celsius ? "°C" : "°F")"
    }
    private func sideCard(_ side: SystemThermalSnapshot.BedSide) -> some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(settings.sideName(for: side.side)).font(.headline)
                Text("\(side.side.displayName) · \(side.direction)").font(.subheadline).foregroundStyle(side.verdict == "stalled" ? Theme.red : Theme.text2)
                if let note = side.note { Text(note).font(.footnote).foregroundStyle(Theme.amber) }
                value("Target", side.isPowered ? temperature(side.targetTempF) : "Off")
                value("Bed", temperature(side.currentTempF))
                value("Pump", side.pumpRpm.map { "\($0.formatted(.number.precision(.fractionLength(0)))) rpm" } ?? "Unknown")
                value("Water", temperature(side.waterTempF))
                value("Surface", temperature(side.bedSurfaceTempF))
                value("Flow reading age", side.readingAgeSec.map { "\(max(0, Int($0))) seconds" } ?? "Unknown")
                if side.guardBlocked { Label("Guard blocked", systemImage: "shield.lefthalf.filled").foregroundStyle(Theme.red) }
                if side.isAlarmVibrating { Label("Inferred alarm vibration", systemImage: "alarm").foregroundStyle(Theme.amber) }
                if let date = SensorCalibrationProfile.date(side.poweredOnAt) { Text("On since \(date.formatted())").font(.caption).foregroundStyle(Theme.text2) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
    private func value(_ title: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { Text(title).foregroundStyle(Theme.text2); Spacer(); Text(value).monospacedDigit() }
            VStack(alignment: .leading, spacing: 4) { Text(title).foregroundStyle(Theme.text2); Text(value).monospacedDigit() }
        }.font(.subheadline)
    }
}
