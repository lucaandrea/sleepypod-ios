import SwiftUI

struct SystemHealthScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SensorStreamService.self) private var sensor
    @State private var model: SystemHealthWorkspace
    @State private var selected: SystemHealthPath.Node?
    @State private var requested: SystemHealthOperation?
    @State private var operation: SystemHealthOperation?
    @State private var confirm = false
    init(client: (any SystemHealthClient)? = nil, calibration: (any SensorCalibrationClient)? = nil) {
        let health = client ?? (APIBackend.current.isDemo ? DemoSystemHealthClient() : CoreSystemHealthClient())
        let calibration = calibration ?? (APIBackend.current.isDemo ? DemoSensorCalibrationClient() : CoreSensorCalibrationClient())
        _model = State(initialValue: .init(client: health, calibration: calibration))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if APIBackend.current.isDemo { Text("DEMO · simulated health checks and recovery").font(.footnote).foregroundStyle(Theme.amber) }
                if let error = model.pathError { Text("Health: \(error). Previously displayed checks may be stale.").foregroundStyle(Theme.amber) }
                if model.loading && model.path == nil { ProgressView("Checking the data path…") }
                if let path = model.path {
                    verdict(path)
                    Text("Data path").font(.headline)
                    Text("Sensors to outputs. Select a stage to inspect its data and connections.").font(.footnote).foregroundStyle(Theme.text2)
                    Text("Checked \(SystemHealthPath.date(path.at).formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(Theme.text2)
                    ForEach(path.orderedStages, id: \.self) { stage in stageCard(stage, path: path) }
                }
                if let error = model.historyError { Text("History: \(error). Any retained history may be stale.").foregroundStyle(Theme.amber) }
                if let history = model.history { SystemHealthHistoryView(history: history) }
                else if model.loading { ProgressView("Reading health history…") }
                Button("Refresh health") { Task { await model.refresh(history: true) } }.disabled(model.loading)
            }.padding(16)
        }.accessibilityIdentifier("health.content").background(Theme.background)
            .preference(key: ExpandedSettingsPresentationKey.self, value: true)
            .navigationTitle("Health").navigationBarTitleDisplayMode(.inline)
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                sensor.connect()
                repeat {
                    await model.refresh()
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                } while !Task.isCancelled
            }
            .task(id: operation) {
                guard let operation else { return }
                await model.perform(operation)
                self.operation = nil
            }
            .sheet(item: $selected) { node in NavigationStack { SystemHealthNodeScreen(model: model, id: node.id) } }
            .alert("Run this recovery action?", isPresented: $confirm) {
                Button("Run recovery") { operation = requested }
                Button("Cancel", role: .cancel) {}
            } message: { Text(confirmationMessage) }
    }
    private var confirmationMessage: String {
        switch requested {
        case .calibrate(let sides): "Keep \(sides.map { $0.displayName.lowercased() }.joined(separator: " and ")) empty and still. This updates capacitance baselines one side at a time."
        case .restart(let unit): "Restart \(unit)? Sensor processing is briefly interrupted. Bed settings are unchanged."
        case nil: "Refresh the current health check before continuing."
        }
    }
    private func ask(_ action: SystemHealthOperation) { requested = action; confirm = true }
    private func verdict(_ path: SystemHealthPath) -> some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(path.verdict.headline, systemImage: path.verdict.tone == "ok" ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.headline).foregroundStyle(path.verdict.tone == "ok" ? Theme.green : path.verdict.tone == "danger" ? Theme.red : Theme.amber)
                    .accessibilityIdentifier("health.verdict")
                if !path.verdict.also.isEmpty { Text("Also: \(path.verdict.also.joined(separator: " · "))").font(.footnote).foregroundStyle(Theme.text2) }
                if let fix = path.verdict.fix { fixActions(fix) }
                if model.acting { ProgressView("Running recovery…") }
                if let notice = model.actionNotice { Text(notice).font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("health.action.notice") }
                if let error = model.actionError { Text(error).font(.footnote).foregroundStyle(Theme.amber).accessibilityIdentifier("health.action.error") }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
    @ViewBuilder private func fixActions(_ fix: SystemHealthPath.Fix) -> some View {
        if fix.kind == "link" {
            if fix.tab == "scheduler" { NavigationLink(fix.label) { SystemSchedulerScreen() } }
            else if fix.tab == "thermal" { NavigationLink(fix.label) { SystemThermalScreen() } }
        } else if fix.kind == "logs", let unit = fix.unit {
            NavigationLink(fix.label) { SystemLogsScreen(unit: unit) }
            if let hint = fix.hint { Text(hint).font(.caption).foregroundStyle(Theme.text2) }
        } else if let unit = fix.unit, SystemHealthPath.restartableUnits.contains(unit) {
            if fix.kind == "occupancy", let sides = fix.sides, !sides.isEmpty {
                Text("Is anyone on the \(sides.map { $0.displayName.lowercased() }.joined(separator: " or ")) side right now?").font(.subheadline)
                Button("No — calibrate empty bed") { ask(.calibrate(sides)) }.disabled(!model.mayAct())
                Button("Yes — restart piezo processor") { ask(.restart(unit)) }.disabled(!model.mayAct())
                NavigationLink("Review calibration") { SensorCalibrationScreen() }
            } else if fix.kind == "restart" {
                Button(fix.label) { ask(.restart(unit)) }.disabled(!model.mayAct()).accessibilityIdentifier("health.restart")
            }
            NavigationLink("View service logs") { SystemLogsScreen(unit: unit) }
        }
    }
    private func stageCard(_ stage: String, path: SystemHealthPath) -> some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(stage.capitalized).font(.headline)
                ForEach(path.nodes.filter { $0.stage == stage }) { node in
                    Button { selected = node } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Label { Text(node.label).foregroundStyle(Theme.text1) } icon: { Circle().fill(node.status.color).frame(width: 8, height: 8) }
                            Text("\(node.status.title) · \(node.metric)").font(.footnote).foregroundStyle(Theme.text2)
                            if node.id == path.verdict.nodeId { Text("Where the chain breaks").font(.caption).foregroundStyle(Theme.amber) }
                            if node.id == path.verdict.lastGoodId { Text("Last with data").font(.caption).foregroundStyle(Theme.text2) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("health.node.\(node.id)")
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
}

private struct SystemHealthNodeScreen: View {
    @Environment(\.dismiss) private var dismiss
    let model: SystemHealthWorkspace
    let id: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let path = model.path, let node = path.nodes.first(where: { $0.id == id }) {
                    Label(node.status.title, systemImage: "circle.fill").foregroundStyle(node.status.color)
                    Text(node.detail).font(.body)
                    Text(node.metric).font(.subheadline.monospacedDigit())
                    if let value = node.path { Text(value).font(.caption.monospaced()).textSelection(.enabled) }
                    if let output = node.lastOutputAt { Text("Last output \(SystemHealthPath.date(output).formatted())").font(.footnote).foregroundStyle(Theme.text2) }
                    else { Text("Last output time is unknown.").font(.footnote).foregroundStyle(Theme.text2) }
                    if let error = model.pathError { Text("Snapshot may be stale: \(error)").foregroundStyle(Theme.amber) }
                    let edges = path.edges.filter { $0.from == id || $0.to == id }
                    if !edges.isEmpty {
                        Text("Connections").font(.headline)
                        ForEach(Array(edges.enumerated()), id: \.offset) { _, edge in
                            Text("\(path.label(edge.from)) → \(path.label(edge.to)) · \(edge.state)").font(.footnote)
                        }
                    }
                    if id == "out-live" { SystemLiveStreamView() }
                    else { NavigationLink("View service logs") { SystemLogsScreen(unit: node.unit ?? "sleepypod.service") } }
                } else { Text("This stage is no longer in the current health snapshot.").foregroundStyle(Theme.text2) }
            }.padding(16)
        }.background(Theme.background).navigationTitle(model.path?.label(id) ?? "Stage").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
    }
}
