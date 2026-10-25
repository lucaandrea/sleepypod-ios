import SwiftUI
import Observation

@MainActor
@Observable
final class UserProfile {
    enum Appearance: String, CaseIterable, Identifiable {
        case system = "System", dark = "Dark", light = "Light"
        var id: String { rawValue }
        var colorScheme: ColorScheme? { self == .system ? nil : self == .dark ? .dark : .light }
    }
    /// Temperature control on the Temp tab; matches sleepypod-core's `control` pref plus the native Both-sides layout.
    enum TempControl: String, CaseIterable, Identifiable {
        case dial, slider, stepper, sides
        var id: String { rawValue }
        var title: String {
            switch self {
            case .dial: "Dial"
            case .slider: "Slider"
            case .stepper: "Night & Dawn"
            case .sides: "Both sides"
            }
        }
    }
    var tempControl: TempControl {
        didSet { UserDefaults.standard.set(tempControl.rawValue, forKey: "tempControl") }
    }
    var temperatureDisplay: TemperatureDisplay {
        didSet { UserDefaults.standard.set(temperatureDisplay.rawValue, forKey: "temperatureDisplay") }
    }
    var temperatureLayout: TemperatureLayout {
        didSet { UserDefaults.standard.set(temperatureLayout.rawValue, forKey: "temperatureLayout") }
    }
    var stageZones: StageZoneVisibility {
        didSet { UserDefaults.standard.set(stageZones.rawValue, forKey: "stageZones") }
    }
    var stageAutoReturn: Bool {
        didSet { UserDefaults.standard.set(stageAutoReturn, forKey: "stageAutoReturn") }
    }
    var appearance: Appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
    }
    var developer: Bool {
        didSet { UserDefaults.standard.set(developer, forKey: "developerMode") }
    }
    var onboardingComplete: Bool {
        didSet { UserDefaults.standard.set(onboardingComplete, forKey: "onboardingComplete") }
    }
    var name: String {
        didSet { UserDefaults.standard.set(name, forKey: "userName") }
    }
    var defaultSide: Side {
        didSet { UserDefaults.standard.set(defaultSide.rawValue, forKey: "userDefaultSide") }
    }

    init() {
        let legacyRelative = UserDefaults.standard.string(forKey: "temperatureFormat") == "relative"
        temperatureDisplay = TemperatureDisplay(rawValue: UserDefaults.standard.string(forKey: "temperatureDisplay") ?? "") ?? (legacyRelative ? .offset : .degrees)
        temperatureLayout = TemperatureLayout(rawValue: UserDefaults.standard.string(forKey: "temperatureLayout") ?? "cards") ?? .cards
        stageZones = StageZoneVisibility(rawValue: UserDefaults.standard.string(forKey: "stageZones") ?? "selected") ?? .selected
        stageAutoReturn = UserDefaults.standard.object(forKey: "stageAutoReturn") as? Bool ?? true
        tempControl = TempControl(rawValue: UserDefaults.standard.string(forKey: "tempControl") ?? "dial") ?? .dial
        let savedAppearance = UserDefaults.standard.string(forKey: "appearance") ?? "System"
        appearance = Appearance.allCases.first { $0.rawValue.lowercased() == savedAppearance.lowercased() } ?? .system
        developer = UserDefaults.standard.bool(forKey: "developerMode")
        // Retain a configured Free Sleep installation when updating to the combined app.
        let savedController = UserDefaults.standard.string(forKey: "podURL") ?? ""
        onboardingComplete = UserDefaults.standard.bool(forKey: "onboardingComplete") || !savedController.isEmpty
        self.name = UserDefaults.standard.string(forKey: "userName") ?? ""
        let sideRaw = UserDefaults.standard.string(forKey: "userDefaultSide")
            ?? UserDefaults.standard.string(forKey: "bedSide") ?? "left"
        self.defaultSide = Side(rawValue: sideRaw) ?? .left
    }

    var displayName: String {
        name.isEmpty ? defaultSide.displayName : name
    }

    var initial: String {
        if name.isEmpty { return defaultSide.initial }
        return String(name.prefix(1)).uppercased()
    }
}
