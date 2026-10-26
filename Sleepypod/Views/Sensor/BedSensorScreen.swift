import SwiftUI

struct BedSensorScreen: View {
    @Environment(SensorStreamService.self) private var sensor
    @Environment(SettingsManager.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var model: SensorDiagnosticsWorkspace
    @State private var streamEnabled = true
    @State private var showConsole = false
    init() {
        _model = State(initialValue: .init(client: APIBackend.current.isDemo ? DemoSensorDiagnosticsClient() : CoreSensorDiagnosticsClient()))
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if APIBackend.current.isDemo { Text("DEMO · simulated sensor observations").font(.footnote).foregroundStyle(Theme.amber) }
                connectionBar
                ThermalBedCard(stored: model.bed)
                TimelineView(.periodic(from: .now, by: 1)) { _ in sensorMatrixCard }
                SensorPresenceCard()
                SensorFreezerCard(model: model)
                PiezoWaveformView()
                estimates
                SensorHistoryCards(model: model)
                SensorFlowCard(model: model)
                Button { showConsole = true } label: {
                    Text("Firmware logs and raw frames").frame(minHeight: 44)
                }.accessibilityIdentifier("sensors.console")
                ForEach(model.errors.keys.sorted(), id: \.self) { section in
                    Text("\(section): \(model.errors[section] ?? "Unavailable"). Retained readings may be stale.").font(.footnote).foregroundStyle(Theme.amber)
                }
            }.padding(16)
        }.accessibilityIdentifier("sensors.content").background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: scenePhase) {
                guard scenePhase == .active else { sensor.disconnect(); return }
                if streamEnabled { sensor.connect() }
                repeat {
                    await model.refreshReadings()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                } while !Task.isCancelled
            }
            .onDisappear { sensor.disconnect() }
            .sheet(isPresented: $showConsole) {
                NavigationStack {
                    ScrollView {
                        FirmwareLogConsoleView(logs: sensor.firmwareLogs, recentFrames: sensor.recentFrames, onClear: { sensor.clearLogs() }).padding(16)
                    }.background(Theme.background).navigationTitle("Sensor console").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showConsole = false } } }
                }
            }
    }
    private var connectionBar: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 10) {
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout())
                layout {
                    Label(streamEnabled ? (sensor.isConnected ? "Connected" : "Connecting") : "Paused", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(sensor.isConnected ? Theme.green : Theme.text2)
                    if !typeSize.isAccessibilitySize { Spacer() }
                    Button(streamEnabled ? "Pause" : "Start") {
                        streamEnabled.toggle()
                        if streamEnabled { sensor.connect() } else { sensor.disconnect() }
                    }.accessibilityIdentifier("sensors.streamToggle")
                }
                if let measured = sensor.lastSensorTime {
                    let age = max(0, Int(Date.now.timeIntervalSince(measured)))
                    Text("\(sensor.framesPerSecond) fps · latest sensor measurement \(age)s old")
                        .font(.caption.monospacedDigit()).foregroundStyle(age > 30 ? Theme.amber : Theme.text2)
                } else { Text("Waiting for measured sensor data").font(.caption).foregroundStyle(Theme.text2) }
                if let error = sensor.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
            }.cardStyle()
        }
    }
    private var estimates: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 12) {
                Text("PIEZO ESTIMATES").font(.caption.weight(.semibold)).foregroundStyle(Theme.text2)
                ForEach(Side.allCases) { side in
                    let vitals = side == .left ? sensor.leftVitals : sensor.rightVitals
                    let fresh = SensorObservation.fresh(sensor.vitalsUpdatedAt, age: 10, now: .now) && vitals.confidence > 0.15
                    SensorDiagnosticValue(title: settings.sideName(for: side), value: fresh ? "\(vitals.heartRate.map { String(format: "%.0f bpm", $0) } ?? "—") · \(vitals.breathingRate.map { String(format: "%.0f breaths/min", $0) } ?? "—")" : "—")
                }
                Text("Calculated locally from the current waveform. These estimates are separate from the controller’s processed sleep records.")
                    .font(.caption).foregroundStyle(Theme.text2)
            }.cardStyle()
        }
    }
    private var sensorMatrixCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.accent)
                Text("SENSOR MATRIX")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.textSecondary)
                    .tracking(1)
            }

            HStack {
                Text("LEFT")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(Theme.accent)
                    .tracking(1.5)
                    .frame(maxWidth: .infinity)
                Spacer().frame(width: 36)
                Text("RIGHT")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(Color(hex: "40e0d0"))
                    .tracking(1.5)
                    .frame(maxWidth: .infinity)
            }

            BedMatrixView(
                leftPresence: sensor.presenceIsFresh ? sensor.leftPresence : nil,
                rightPresence: sensor.presenceIsFresh ? sensor.rightPresence : nil,
                leftVariance: sensor.presenceIsFresh ? sensor.leftVariance : [],
                rightVariance: sensor.presenceIsFresh ? sensor.rightVariance : [],
                leftTemps: SensorObservation.fresh(sensor.bedTempUpdatedAt) ? sensor.leftTemps : nil,
                rightTemps: SensorObservation.fresh(sensor.bedTempUpdatedAt) ? sensor.rightTemps : nil
            )
        }
        .cardStyle()
    }

}
