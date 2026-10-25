import AppIntents

struct GetTemperatureIntent: AppIntent {
    static let title: LocalizedStringResource = "Get bed temperature"
    static let description = IntentDescription("Return the current or target temperature in Fahrenheit for use in your Shortcuts.")
    @Parameter(title: "Side", default: .left) var side: BedSide
    @Parameter(title: "Reading", default: .current) var reading: TemperatureReading
    static var parameterSummary: some ParameterSummary { Summary("Get the \(\.$side) bed’s \(\.$reading) temperature in Fahrenheit") }
    func perform() async throws -> some IntentResult & ReturnsValue<Double> {
        .result(value: try await PodActions.temperature(side: side, reading: reading))
    }
}
