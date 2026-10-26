import SwiftUI

struct SystemDashboardScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SettingsManager.self) private var settings
    @Environment(DeviceManager.self) private var device
    @Environment(StatusManager.self) private var status
    @State private var model: SystemDashboardWorkspace
    @State private var showWater = false
    private var sides: [Side] { settings.settings?.shownSides ?? Side.allCases }
    init() {
        let demo = APIBackend.current.isDemo
        _model = State(initialValue: .init(client: demo ? DemoSystemDashboardClient() : CoreSystemDashboardClient(),
                                          health: demo ? DemoSystemHealthClient() : CoreSystemHealthClient(),
                                          thermal: demo ? DemoSystemThermalClient() : CoreSystemThermalClient(),
                                          scheduler: demo ? DemoSystemSchedulerClient() : CoreSystemSchedulerClient()))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if APIBackend.current.isDemo { Text("DEMO · simulated controller overview").font(.footnote).foregroundStyle(Theme.amber) }
                ForEach(model.errors.keys.sorted(), id: \.self) { section in
                    Text("\(section): \(model.errors[section] ?? "Unavailable"). Retained readings may be stale.").font(.footnote).foregroundStyle(Theme.amber)
                }
                if model.loading && model.runtime == nil { ProgressView("Reading controller overview…") }
                if let firewall = status.serverStatus?.coreFirewall {
                    GroupedCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(firewall.ok ? "Firewall rules are in place" : "Firewall rules are missing", systemImage: "network.badge.shield.half.filled")
                                .font(.headline).foregroundStyle(firewall.ok ? Theme.green : Theme.amber)
                            if !firewall.missing.isEmpty { Text(firewall.missing.joined(separator: " · ")).font(.footnote) }
                            if !status.statusIsFresh() { Text("Last reported firewall state; current status is unavailable.").font(.footnote).foregroundStyle(Theme.amber) }
                            NavigationLink("Connection settings") { OwnerConnectionView() }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                } else { Text("Firewall status is unavailable.").font(.footnote).foregroundStyle(Theme.text2) }
                if let runtime = model.runtime { SystemRuntimeCard(runtime: runtime) }
                NavigationLink("Pump alerts and incident history") { PumpAlertsScreen() }.accessibilityIdentifier("dashboard.pumpAlerts")
                attention
                if let health = model.health {
                    GroupedCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(health.verdict.headline).font(.headline)
                            let suspect = sides.filter { health.occupancy[$0.rawValue] == "suspect" }
                            if !suspect.isEmpty {
                                Text("\(suspect.map { settings.sideName(for: $0) }.joined(separator: " and ")): occupied without recent vitals or movement. Review whether someone is in bed before recalibrating or restarting processing.").font(.footnote).foregroundStyle(Theme.amber)
                            }
                            NavigationLink("Inspect health and recovery") { SystemHealthScreen() }.accessibilityIdentifier("dashboard.health")
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                }
                if let timeline = model.timeline, let night = DashboardNight(timeline: timeline) {
                    SystemDashboardNightCard(night: night, history: model.history, sides: sides)
                }
                if let thermal = model.thermal {
                    ForEach(thermal.sides.filter { sides.contains($0.side) }) { side in
                        SystemDashboardSideCard(side: side, history: model.history, fresh: model.fresh("Thermal"))
                    }
                }
                Button("Refresh overview") { Task { await model.refresh(details: true) } }.disabled(model.loading)
                if let date = model.receivedAt["Thermal"] { Text("Delivery reading received \(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(Theme.text2) }
            }.padding(16)
        }.accessibilityIdentifier("dashboard.content").background(Theme.background)
            .navigationTitle("Overview").navigationBarTitleDisplayMode(.inline)
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                repeat {
                    async let serviceStatus: () = status.fetchAll()
                    async let overview: () = model.refresh()
                    _ = await (serviceStatus, overview)
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                } while !Task.isCancelled
            }
            .sheet(isPresented: $showWater) { WaterLevelSheet(currentLevel: device.deviceStatus?.waterLevel ?? "unknown") }
    }
    private func podDate(_ milliseconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: settings.timeZone) ?? .gmt
        formatter.setLocalizedDateFormatFromTemplate("MMM d jmm")
        return formatter.string(from: SystemHealthPath.date(milliseconds))
    }
    @ViewBuilder private var attention: some View {
        if let maintenance = model.maintenance {
            GroupedCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Maintenance").font(.headline)
                    if !model.fresh("Maintenance") { Text("These maintenance facts may be stale.").font(.footnote).foregroundStyle(Theme.amber) }
                    if maintenance.needsPumpProtection {
                        Label("Pump-stall protection is off", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.amber)
                        NavigationLink("Review pump protection") { PumpProtectionSettingsScreen() }.accessibilityIdentifier("dashboard.protection")
                    }
                    if device.deviceStatus?.waterLevel == "low" { Label("Water is low. Refill the tank before priming.", systemImage: "drop").foregroundStyle(Theme.amber) }
                    if maintenance.needsPrime(at: .now) {
                        Text(maintenance.lastPrimeAt == nil ? "No prime has been recorded." : "No prime in the last seven days.").foregroundStyle(Theme.amber)
                    }
                    if maintenance.primePodDaily { Text("Daily prime is enabled\(maintenance.primePodTime.map { " at \($0)" } ?? "").").font(.footnote) }
                    if let last = maintenance.lastPrimeAt {
                        Text("Last prime: \(podDate(last))").font(.footnote).foregroundStyle(Theme.text2)
                    }
                    Button(device.deviceStatus?.isPriming == true ? "Priming…" : "Review water and priming") { showWater = true }
                        .accessibilityIdentifier("dashboard.priming")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        }
    }
}
