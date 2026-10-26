import SwiftUI

struct SensorCalibrationScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SettingsManager.self) private var settings
    @Environment(SensorStreamService.self) private var sensor
    @State private var model: SensorCalibrationWorkspace
    @State private var side: Side = .left
    @State private var confirm = false
    @State private var requested: CalibrationTarget?
    let onComplete: () -> Void
    init(client: (any SensorCalibrationClient)? = nil, onComplete: @escaping () -> Void = {}) {
        let chosen = client ?? (APIBackend.current.isDemo ? DemoSensorCalibrationClient() : CoreSensorCalibrationClient())
        _model = State(initialValue: .init(client: chosen)); self.onComplete = onComplete
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if APIBackend.current.isDemo { Text("DEMO · simulated calibration and signals").font(.footnote).foregroundStyle(Theme.amber) }
                Picker("Calibration side", selection: $side) {
                    ForEach(Side.allCases) { side in Text(sideLabel(side)).tag(side) }
                }.accessibilityIdentifier("calibration.side")
                Text("Keep the selected side empty and still. A quiet five-minute window in the last six hours is needed. Calibrate all applies to both sides.").font(.footnote).foregroundStyle(Theme.text2)
                Button("Calibrate all") { requested = nil; confirm = true }.disabled(!model.canTrigger).accessibilityIdentifier("calibration.all")
                if model.loading && model.statuses.isEmpty { ProgressView("Reading calibration…") }
                if let notice = model.notice { Text(notice).foregroundStyle(model.completed ? Theme.green : Theme.text2).accessibilityIdentifier("calibration.notice") }
                if let error = model.actionError { Text(error).foregroundStyle(Theme.amber) }
                ForEach(Side.allCases) { side in
                    if let error = model.errors[side] { Text("\(side.displayName): \(error). Displayed profiles may be stale.").foregroundStyle(Theme.amber) }
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ForEach(CalibrationKind.allCases) { kind in card(kind, at: context.date) }
                }
                Button("Refresh calibration") { Task { await model.refresh() } }.disabled(model.loading)
                if let received = model.receivedAt[side] { Text("Read \(received.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(Theme.text2) }
                Text("Queued work continues on the controller if you leave this screen. A successful request alone does not mean calibration completed.").font(.caption).foregroundStyle(Theme.text2)
            }.padding(16)
        }.accessibilityIdentifier("calibration.content").background(Theme.background)
            .navigationTitle("Calibration").navigationBarTitleDisplayMode(.inline)
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                sensor.connect()
                repeat {
                    await model.refresh()
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                } while !Task.isCancelled
            }
            .onChange(of: model.completed) { _, completed in if completed { onComplete() } }
            .alert(requested.map { "Calibrate \($0.label)?" } ?? "Calibrate all sensors on both sides?", isPresented: $confirm) {
                Button("Start calibration") { Task { await model.trigger(requested); await model.refresh() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("The selected side must be empty and still. Calibration updates the controller's sensor baselines.") }
    }
    private func sideLabel(_ side: Side) -> String {
        let name = settings.sideName(for: side)
        return name.localizedCaseInsensitiveCompare(side.displayName) == .orderedSame ? side.displayName : "\(name) · \(side.displayName)"
    }
    private func card(_ kind: CalibrationKind, at now: Date) -> some View {
        let profile = model.statuses[side]?[kind]
        return GroupedCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(kind.title).font(.headline)
                Text(kind.detail).font(.subheadline).foregroundStyle(Theme.text2)
                Text((profile?.status ?? "unknown").uppercased()).font(.caption.monospaced()).foregroundStyle(profile?.status == "completed" ? Theme.green : profile?.status == "failed" ? Theme.red : Theme.text2)
                CalibrationSignalChart(kind: kind, side: side, profile: profile, buffer: sensor.calibrationSignals, now: now)
                Text(profile?.qualityScore.map { "\(($0 * 100).formatted(.number.precision(.fractionLength(0))))% quality" } ?? "Quality unknown").font(.title3.monospacedDigit())
                Text(profile?.samplesUsed.map { "\($0.formatted()) samples" } ?? "Sample count unknown").font(.footnote)
                if let created = profile?.created { Text("Calibrated \(created.formatted())").font(.caption).foregroundStyle(Theme.text2) }
                if let validity = profile?.validity(at: now) {
                    ProgressView(value: validity.remaining).accessibilityLabel("Calibration validity remaining")
                    Text(validity.seconds <= 0 ? "Expired" : "\(Int(ceil(validity.seconds / 3600))) hours of validity left").font(.caption).foregroundStyle(validity.seconds <= 0 ? Theme.amber : Theme.text2)
                } else { Text("Validity unknown").font(.caption).foregroundStyle(Theme.text2) }
                if let error = profile?.errorMessage { Text(error).foregroundStyle(Theme.amber) }
                Button(profile == nil ? "Calibrate \(kind.title)" : "Recalibrate \(kind.title)") {
                    requested = .init(side: side, kind: kind); confirm = true
                }.disabled(!model.canTrigger).accessibilityIdentifier("calibration.trigger.\(kind.rawValue)")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
}
