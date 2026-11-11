import SwiftUI

struct BedCareScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = BedCareWorkspace()
    @State private var refreshRevision = 0
    @State private var recoveryExpanded = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(at: timeline.date)
                    if let report = model.report { observations(report, at: timeline.date) }
                    recovery
                }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }.background(Theme.background)
        }
        .navigationTitle("Bed care")
        .task(id: OwnerConnection.revision + [String(describing: scenePhase), String(refreshRevision)]) {
            model.invalidate()
            guard scenePhase == .active else { return }
            let client: (any BedCareClient)?
            if APIBackend.current.isDemo { client = DemoBedCareClient() }
            else if APIBackend.current == .sleepypodCore, let transport = try? CoreRESTClient.configured() { client = CoreBedCareClient(transport: transport) }
            else { client = nil }
            model.configure(client: client)
            repeat {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            } while !Task.isCancelled
        }
        .onDisappear { model.invalidate() }
    }

    private func observations(_ report: BedCare, at date: Date) -> some View {
        let reportCurrent = report.current(at: date)
        let lastID = report.checks.last?.id
        return VStack(alignment: .leading, spacing: 20) {
            ForEach(report.checks) { check in
                BedCareRow(check: check, current: reportCurrent && check.current(at: date), exportDate: report.exportDate)
                if check.id != lastID { Divider() }
            }
        }.padding(20).cardStyle()
    }

    private func header(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Look after your bed").font(.title2.weight(.semibold))
            if APIBackend.current.isDemo {
                Label("Practice · simulated care checks", systemImage: "play.circle").font(.subheadline).foregroundStyle(Theme.text2)
            }
            Text("Start with what needs attention. These checks explain the Pod’s reports; they do not inspect the mattress or detect leaks.")
                .font(.subheadline).foregroundStyle(Theme.text2)
            if let report = model.report, report.current(at: date) {
                Text("Checked \(report.checkedDate.formatted(date: .omitted, time: .standard)). Each source is checked separately.").font(.footnote).foregroundStyle(Theme.text2)
            } else {
                Text(model.error ?? (model.loading ? "Reading care checks…" : "Care checks unavailable. Reconnect and check again; saved information cannot establish the bed’s current condition."))
                    .font(.subheadline).foregroundStyle(Theme.text2).accessibilityIdentifier("care.unavailable")
            }
            Button(model.loading ? "Checking…" : "Check again", systemImage: "arrow.clockwise") { refreshRevision += 1 }
                .disabled(model.loading).frame(minHeight: 44).accessibilityIdentifier("care.refresh")
        }
    }
    private var recovery: some View {
        DisclosureGroup(isExpanded: $recoveryExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                Text("1. Check the connection and affected source. An unavailable reading is not a clean bill of health.")
                Text("2. Before software maintenance, export a backup from Databases and keep a private copy on another device. Verify the archive and rehearse restoration before replacing the controller.")
                Text("3. Open the relevant diagnostics and follow the specific recovery instructions. Do not clear circulation protection merely to hide an alert.")
                Text("4. Recheck after repair. Confirm temperature, vibration and base movement separately when those functions are affected.")
                Text("For water, hoses or a maintenance insert, use instructions for your exact Pod generation. Insert age and physical leaks are not measured here. A factory reset can remove this custom installation.")
                Link("Find instructions for your Pod", destination: URL(string: "https://help.eightsleep.com/")!).frame(minHeight: 44)
                    .accessibilityIdentifier("care.instructions")
            }.font(.subheadline).foregroundStyle(Theme.text2).padding(.top, 12)
        } label: {
            Text("A careful recovery, step by step").font(.headline).frame(minHeight: 44).accessibilityIdentifier("care.recovery")
        }
    }
}

private struct BedCareRow: View {
    let check: BedCare.Check
    let current: Bool
    let exportDate: Date?
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(check.title).font(.headline).accessibilityIdentifier("care.\(check.id)")
            Label(current ? check.statusLabel : "Not verified", systemImage: icon).font(.subheadline).foregroundStyle(Theme.text2)
            Text(current ? check.detail : "A current check is unavailable. Read the last observation below or try again.").font(.subheadline)
            if check.id == "backup", let exportDate {
                Text("Last recorded export: \(exportDate.formatted()). This is not proof of a saved off-Pod backup.").font(.footnote).foregroundStyle(Theme.text2)
            }
            Text(check.advice(current: current)).font(.subheadline).foregroundStyle(Theme.text2)
            if !current || !check.evidence.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        if !current {
                            if let observed = check.observedAt {
                                Text("Observed \(Date(timeIntervalSince1970: observed / 1000).formatted()).").font(.footnote).foregroundStyle(Theme.text2)
                            }
                            Text(check.detail).font(.subheadline).foregroundStyle(Theme.text2)
                            Text("Advice for that observation: \(check.nextStep)").font(.subheadline).foregroundStyle(Theme.text2)
                        }
                        ForEach(check.evidence, id: \.title) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.subheadline.weight(.semibold))
                                Text(item.detail).font(.subheadline).foregroundStyle(Theme.text2)
                            }
                        }
                    }.padding(.top, 10)
                } label: { Text(current ? "See individual checks" : "See last observation").frame(minHeight: 44) }
            }
            NavigationLink { destination } label: { Label(check.destinationLabel, systemImage: "arrow.right").font(.subheadline).frame(minHeight: 44) }
                .accessibilityIdentifier("care.open.\(check.id)")
            if check.id == "circulation" {
                NavigationLink { PumpProtectionSettingsScreen() } label: {
                    Label("Review protection settings", systemImage: "shield").font(.subheadline).frame(minHeight: 44)
                }.accessibilityIdentifier("care.open.protectionSettings")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var icon: String {
        guard current else { return "questionmark.circle" }
        switch check.state {
        case "checked": return "checkmark.circle"
        case "attention": return "exclamationmark.triangle"
        case "busy": return "clock"
        default: return "questionmark.circle"
        }
    }
    @ViewBuilder private var destination: some View {
        switch check.destination {
        case "thermal": SystemThermalScreen()
        case "dashboard": PumpAlertsScreen()
        case "health": SystemHealthScreen()
        case "storage": SystemStorageScreen()
        default: SystemDatabaseScreen()
        }
    }
}
