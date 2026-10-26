import SwiftUI

struct TemperatureApplicationScreen: View {
    @Environment(SettingsManager.self) private var settings
    @State private var side = Side.left
    @State private var workspace = TemperatureApplicationWorkspace(client: {
        if APIBackend.current.isDemo { return TemperatureApplicationExample(scenario: DebugRoute.temperatureApplicationScenario) }
        guard APIBackend.current == .sleepypodCore else { throw APIError.serverError(message: "Connect to a compatible controller to view this history.") }
        return CoreTemperatureApplicationClient(transport: try .configured())
    })
    @AppStorage("ownerConnectionRevision") private var connectionRevision = ""
    @AppStorage("apiBackend") private var backend = ""
    @AppStorage("podURL") private var endpoint = ""
    @AppStorage("podIPAddress") private var host = ""
    private var scope: [String] { [connectionRevision, backend, endpoint, host, side.rawValue] }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if APIBackend.current.isDemo { Eyebrow("SYNTHETIC EXAMPLE · NOT YOUR BED", color: Theme.amber) }
                Picker("Bed side", selection: $side) {
                    Text("Left side").tag(Side.left)
                    Text("Right side").tag(Side.right)
                }.pickerStyle(.menu).accessibilityIdentifier("temperatureApplications.side")
                Text("Requested targets and controller results. Measured bed temperatures are shown in Sensors.")
                    .font(.subheadline).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                if let date = workspace.generatedAt {
                    Text("Read \(date.formatted(date: .abbreviated, time: .standard)) · this device’s time zone")
                        .font(.caption).foregroundStyle(Theme.text2)
                }
                Button { Task { await workspace.reload(side: side) } } label: {
                    Label("Refresh history", systemImage: "arrow.clockwise")
                }.disabled(workspace.loading).accessibilityIdentifier("temperatureApplications.refresh")
                if workspace.loading { ProgressView("Reading history…") }
                if let error = workspace.error {
                    Text(error).font(.subheadline).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("temperatureApplications.error")
                }
                if workspace.items.isEmpty && !workspace.loading && workspace.error == nil {
                    ContentUnavailableView("No recorded applications", systemImage: "thermometer.medium",
                        description: Text("No target attempts are retained for this side. Earlier commands are not backfilled."))
                        .accessibilityIdentifier("temperatureApplications.empty")
                }
                ForEach(workspace.items) { value in application(value) }
                if workspace.nextBeforeId != nil {
                    Button { Task { await workspace.more() } } label: { Label("Load older applications", systemImage: "clock.arrow.circlepath") }
                        .disabled(workspace.loading).accessibilityIdentifier("temperatureApplications.more")
                }
                Text("Up to 30 days and 10,000 attempts per side. This history covers shared target writes; other bed commands have separate records.")
                    .font(.footnote).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
        }
        .background(Theme.background).foregroundStyle(Theme.text1).tint(Theme.text1)
        .navigationTitle("Temperature applications").navigationBarTitleDisplayMode(.inline)
        .task(id: scope) { await workspace.reload(side: side) }
        .onDisappear { workspace.invalidate() }
    }

    private func application(_ value: TemperatureApplication) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Requested \(temperature(value.targetF))").font(.title3.monospacedDigit()).accessibilityIdentifier("temperatureApplications.target.\(value.id)")
            Text(value.date, format: .dateTime.month().day().hour().minute().second())
                .font(.caption.monospaced()).foregroundStyle(Theme.text2)
            Text(value.label).font(.headline).foregroundStyle(value.outcome == .acknowledged ? Theme.text1 : Theme.amber)
            Text(value.detail).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Text("\(value.reason.label) · \(source(value.source))").font(.footnote).foregroundStyle(Theme.text2)
            if let duration = value.durationSec { Text("Requested duration: \(duration) seconds").font(.footnote).foregroundStyle(Theme.text2) }
            DisclosureGroup("Audit details") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Attempt \(value.attemptId.uuidString.lowercased())")
                    if let request = value.requestId { Text("Source request \(request)") }
                    Text("Recorded attempt IDs identify history. They cannot be used to replay a command.")
                }.font(.caption.monospaced()).foregroundStyle(Theme.text2).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }.accessibilityIdentifier("temperatureApplications.audit.\(value.id)")
        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }
    private func temperature(_ fahrenheit: Double) -> String {
        let celsius = settings.temperatureFormat == .celsius
        let value = celsius ? (fahrenheit - 32) * 5 / 9 : fahrenheit
        return value.formatted(.number.precision(.fractionLength(0...1))) + (celsius ? "°C" : "°F")
    }
    private func source(_ value: String?) -> String {
        switch value {
        case "manual": "Manual control"
        case "run-once": "Run once"
        case "autopilot": "Autopilot"
        case "schedule": "Schedule"
        default: "No selected owner"
        }
    }
}
