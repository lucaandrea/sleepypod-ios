import AppIntents

struct SetTemperatureIntent: AppIntent {
    static let title: LocalizedStringResource = "Set bed temperature"
    static let description = IntentDescription("Set the target temperature for one side of your Pod.")
    @Parameter(title: "Side", default: .left) var side: BedSide
    @Parameter(title: "Temperature in Fahrenheit", default: 80) var temperature: Double
    static var parameterSummary: some ParameterSummary { Summary("Set \(\.$side) bed temperature to \(\.$temperature)°F") }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard temperature.isFinite, (55...110).contains(temperature) else { throw PodError.message("Choose a temperature from 55 to 110°F.") }
        try await PodActions.client().post("deviceStatus", body: [side.rawValue: ["targetTemperatureF": temperature]])
        return .result(dialog: "The \(side.rawValue) target temperature was sent to your Pod.")
    }
}
