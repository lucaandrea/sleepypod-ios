import SwiftUI

/// Both tabs belong to the personal workspace; neither mounts the owner managers or streams.
struct HouseholdRootView: View {
    @Environment(HouseholdWorkspace.self) private var household
    var body: some View {
        Group {
            if let temperature = household.temperature {
                TabView {
                    Tab("Temp", systemImage: "thermometer.medium") { PersonalTemperatureScreen(model: temperature) }
                    Tab("Account", systemImage: "person.crop.circle") { HouseholdScreen() }
                }
            } else { HouseholdScreen() }
        }
    }
}
