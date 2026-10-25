import SwiftUI

struct AppearanceSettingsScreen: View {
    @Environment(UserProfile.self) private var profile
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        @Bindable var profile = profile
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                GroupedSection("TEMPERATURE") {
                    GroupedCard {
                        SettingsRow("Layout", icon: "cube", tile: true) {
                            Picker("Temperature layout", selection: $profile.temperatureLayout) {
                                ForEach(TemperatureLayout.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden()
                        }
                        TempControlMenu(selection: $profile.tempControl, iconColor: Theme.icon, tile: true)
                        SettingsRow("Show as", icon: "thermometer.medium", tile: true) {
                            Picker("Show temperature as", selection: $profile.temperatureDisplay) {
                                ForEach(TemperatureDisplay.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden().accessibilityIdentifier("temperature.display")
                        }
                        SettingsRow("Units", icon: "ruler", tile: true) {
                            Picker("Temperature units", selection: Binding(get: { settings.temperatureFormat.degreeUnit }, set: { unit in
                                Task { await settings.updateTemperatureFormat(unit) }
                            })) {
                                Text("°F").tag(TemperatureFormat.fahrenheit)
                                Text("°C").tag(TemperatureFormat.celsius)
                            }.labelsHidden()
                        }
                    }
                    Text("Offset counts whole degrees from 80°F. Eight Sleep uses −10…+10 levels, with 0 at 82.5°F. Sensor readings always show actual degrees.")
                        .font(.footnote).foregroundStyle(Theme.text2).padding(.horizontal, 16)
                }
                GroupedSection("3D STAGE") {
                    GroupedCard {
                        SettingsRow("Zone readings", icon: "square.grid.3x3", tile: true) {
                            Picker("Zone readings", selection: $profile.stageZones) {
                                ForEach(StageZoneVisibility.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden().accessibilityIdentifier("temperature.zones")
                        }
                        SettingsRow("Return camera", icon: "arrow.counterclockwise", tile: true) {
                            Toggle("Return camera after a pause", isOn: $profile.stageAutoReturn).labelsHidden()
                        }
                    }
                }
                GroupedSection("DISPLAY") {
                    GroupedCard {
                        SettingsRow("Theme", icon: "circle.lefthalf.filled", tile: true) {
                            Picker("Theme", selection: $profile.appearance) {
                                ForEach(UserProfile.Appearance.allCases) { Text($0.rawValue).tag($0) }
                            }.labelsHidden()
                        }
                    }
                }
                if let error = settings.error { Text(error).font(.footnote).foregroundStyle(Theme.red) }
            }.padding(16)
        }
        .background(Theme.background).navigationTitle("Appearance")
    }
}
