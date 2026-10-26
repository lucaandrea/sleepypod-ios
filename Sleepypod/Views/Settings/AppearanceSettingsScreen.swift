import SwiftUI

struct AppearanceSettingsScreen: View {
    @Environment(UserProfile.self) private var profile
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        @Bindable var profile = profile
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                GroupedSection("TEMPERATURE") {
                    GroupedCard {
                        AppearanceChoice(title: "Layout", icon: "cube", selection: $profile.temperatureLayout, options: TemperatureLayout.allCases.map { ($0, $0.title) }, identifier: "appearance.layout")
                        AppearanceChoice(title: "Temperature control", icon: "dial.medium", selection: $profile.tempControl, options: UserProfile.TempControl.allCases.map { ($0, $0.title) }, identifier: "appearance.control")
                        AppearanceChoice(title: "Show as", icon: "thermometer.medium", selection: $profile.temperatureDisplay, options: TemperatureDisplay.allCases.map { ($0, $0.title) }, identifier: "temperature.display")
                        AppearanceChoice(title: "Units", icon: "ruler", selection: Binding(get: { settings.temperatureFormat.degreeUnit }, set: { unit in
                            Task { await settings.updateTemperatureFormat(unit) }
                        }), options: [(.fahrenheit, "°F"), (.celsius, "°C")], identifier: "appearance.units")
                            .disabled(settings.settings == nil || settings.isSaving || settings.mustReloadSettings)
                    }
                    Text("Offset counts whole degrees from 80°F. Eight Sleep uses −10…+10 levels, with 0 at 82.5°F. Sensor readings always show actual degrees.")
                        .font(.footnote).foregroundStyle(Theme.text2).padding(.horizontal, 16)
                    SettingsMutationFeedback().padding(.horizontal, 16)
                }
                GroupedSection("3D STAGE") {
                    GroupedCard {
                        AppearanceChoice(title: "Zone readings", icon: "square.grid.3x3", selection: $profile.stageZones, options: StageZoneVisibility.allCases.map { ($0, $0.title) }, identifier: "temperature.zones")
                        if typeSize.isAccessibilitySize {
                            BridgeToggleRow(title: "Return camera", value: $profile.stageAutoReturn, identifier: "appearance.autoReturn").padding(16)
                        } else {
                            SettingsRow("Return camera", icon: "arrow.counterclockwise", tile: true) {
                                Toggle("Return camera after a pause", isOn: $profile.stageAutoReturn).labelsHidden().accessibilityIdentifier("appearance.autoReturn")
                            }
                        }
                    }
                    Text("Return the camera after a pause in rotation or zoom.").font(.footnote).foregroundStyle(Theme.text2).padding(.horizontal, 16)
                }
                GroupedSection("DISPLAY") {
                    GroupedCard {
                        AppearanceChoice(title: "Theme", icon: "circle.lefthalf.filled", selection: $profile.appearance, options: UserProfile.Appearance.allCases.map { ($0, $0.rawValue) }, identifier: "appearance.theme")
                    }
                }
            }.frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(profile.appearance.colorScheme)
            .accessibilityIdentifier("appearance.content").task { await settings.fetchSettings() }
    }
}

private struct AppearanceChoice<Value: Hashable & RawRepresentable>: View where Value.RawValue == String {
    @Environment(\.dynamicTypeSize) private var size
    let title: String
    let icon: String
    @Binding var selection: Value
    let options: [(Value, String)]
    let identifier: String
    var body: some View {
        if size.isAccessibilitySize {
            SettingsChoiceMenu(title: title, selection: Binding(get: { selection.rawValue }, set: { if let value = Value(rawValue: $0) { selection = value } }), options: options.map { ($0.0.rawValue, $0.1) }, identifier: identifier)
                .padding(16)
        } else {
            SettingsRow(title, icon: icon, tile: true) {
                Menu {
                    SettingsChoiceOptions(selection: Binding(get: { selection.rawValue }, set: { if let value = Value(rawValue: $0) { selection = value } }), options: options.map { ($0.0.rawValue, $0.1) }, identifier: identifier)
                } label: {
                    HStack(spacing: 8) {
                        Text(options.first { $0.0 == selection }?.1 ?? selection.rawValue)
                        Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(title)
                    .accessibilityValue(options.first { $0.0 == selection }?.1 ?? selection.rawValue)
                    .accessibilityIdentifier(identifier)
            }
        }
    }
}
