import AppIntents

enum TemperatureReading: String, AppEnum {
    case current, target
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Temperature reading")
    static let caseDisplayRepresentations: [TemperatureReading: DisplayRepresentation] = [.current: "Current", .target: "Target"]
}
