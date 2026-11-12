import SwiftUI

/// Both tabs belong to the personal workspace; neither mounts the owner managers or streams.
struct HouseholdRootView: View {
    @Environment(HouseholdWorkspace.self) private var household
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = "temperature"
    var body: some View {
        Group {
            if household.requiresMaintenance {
                NavigationStack {
                    if let maintenance = household.maintenance {
                        ArrangementMaintenanceScreen(model: maintenance, refresh: { await household.refresh() }, close: { household.signOut() })
                    } else {
                        Form {
                            Section { ProgressView("Checking your bed arrangement…") }
                            Section { Button("Close personal session") { household.signOut() } }
                        }.navigationTitle("Bed arrangement")
                    }
                }
            } else if let temperature = household.temperature {
                TabView(selection: $selectedTab) {
                    Tab("Temp", systemImage: "thermometer.medium", value: "temperature") { PersonalTemperatureScreen(model: temperature) }
                    Tab("Account", systemImage: "person.crop.circle", value: "account") { HouseholdScreen() }
                }
            } else { HouseholdScreen() }
        }
        .task { await household.refresh(); await household.personalHealth?.refreshOnActivation() }
        .onReceive(NotificationCenter.default.publisher(for: .openBedWidget)) { _ in selectedTab = "temperature" }
        .onChange(of: scenePhase) { _, phase in Task { await household.sceneChanged(active: phase == .active) } }
    }
}
