import SwiftUI

struct PumpAlertsScreen: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SettingsManager.self) private var settings
    @State private var model: PumpAlertWorkspace
    @State private var reviewed: [PumpAlert] = []
    @State private var confirmDismiss = false
    init() { _model = State(initialValue: .init(client: APIBackend.current.isDemo ? DemoPumpAlertClient() : CorePumpAlertClient())) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if APIBackend.current.isDemo { Text("DEMO · simulated pump alerts").font(.footnote).foregroundStyle(Theme.amber) }
                Text("Unresolved alerts can block a side after a controller restart. Dismiss only incidents that no longer reflect the pump’s condition. Dismissal releases a matching block without turning the side on.")
                    .font(.footnote).foregroundStyle(Theme.text2)
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) { Text("Include acknowledged alerts"); filterToggle.labelsHidden() }
                } else { filterToggle }
                if let error = model.error { Text("Alerts could not be refreshed: \(error). Retained alerts may be stale.").font(.footnote).foregroundStyle(Theme.amber) }
                if let result = model.result { Text(result).font(.footnote).accessibilityIdentifier("pumpAlerts.result") }
                if model.loading { ProgressView("Reading pump alerts…") }
                if model.receivedAt != nil, model.alerts.isEmpty, model.error == nil {
                    ContentUnavailableView("No matching pump alerts", systemImage: "checkmark.shield", description: Text("The controller returned no alerts for this filter."))
                }
                ForEach(model.alerts) { alert in alertCard(alert) }
                if !model.alerts.isEmpty {
                    Button("Dismiss all \(model.alerts.count) shown") { reviewed = model.alerts; confirmDismiss = true }
                        .disabled(!model.canDismiss()).accessibilityIdentifier("pumpAlerts.dismissAll")
                }
                Button("Refresh alerts") { Task { await model.load() } }.disabled(model.loading || model.dismissing)
                Text("Up to 500 alerts, newest first. Dismissed alerts are excluded by the controller.").font(.caption).foregroundStyle(Theme.text2)
            }.padding(16)
        }.accessibilityIdentifier("pumpAlerts.content").background(Theme.background)
            .navigationTitle("Pump alerts").navigationBarTitleDisplayMode(.inline)
            .alert("Dismiss \(reviewed.count) alert\(reviewed.count == 1 ? "" : "s")?", isPresented: $confirmDismiss) {
                Button("Dismiss", role: .destructive) { let selection = reviewed; Task { await model.dismiss(selection) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Clears matching blocks. Power is unchanged.") }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                repeat {
                    await model.load()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                } while !Task.isCancelled
            }
    }
    private var filterToggle: some View {
        Toggle("Include acknowledged alerts", isOn: Binding(get: { model.includesAcknowledged }, set: { value in Task { await model.load(includeAcknowledged: value) } }))
            .disabled(model.loading || model.dismissing).accessibilityIdentifier("pumpAlerts.acknowledged")
    }
    private func alertCard(_ alert: PumpAlert) -> some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(alert.title, systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(Theme.amber)
                Text("\(alert.side.map { settings.sideName(for: $0) } ?? "Both sides") · \(alert.actionLabel)").font(.subheadline)
                if let date = alert.date { Text(date, format: .dateTime.year().month().day().hour().minute().timeZone()).font(.caption).foregroundStyle(Theme.text2) }
                else { Text(alert.timestamp).font(.caption).foregroundStyle(Theme.text2) }
                if alert.acknowledgedAt != nil { Text("Acknowledged").font(.caption).foregroundStyle(Theme.green) }
                if let speed = alert.rpm { LabeledContent("Pump speed", value: "\(speed.formatted()) RPM") }
                if let flow = alert.flowrateCd { LabeledContent("Flow diagnostic", value: flow.formatted()) }
                if let duration = alert.durationSeconds { LabeledContent("Duration", value: "\(duration.formatted()) seconds") }
                if let failure = model.failures[alert.id] { Text("Dismissal was not confirmed: \(failure)").font(.footnote).foregroundStyle(Theme.amber) }
                Button("Dismiss alert") { reviewed = [alert]; confirmDismiss = true }
                    .disabled(!model.canDismiss()).accessibilityIdentifier("pumpAlerts.dismiss.\(alert.id)")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
}
