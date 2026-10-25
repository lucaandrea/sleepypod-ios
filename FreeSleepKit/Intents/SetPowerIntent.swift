import AppIntents

struct SetPowerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set bed power"
    @Parameter(title: "Side", default: .left) var side: BedSide
    @Parameter(title: "Turn on", default: true) var enabled: Bool
    static var parameterSummary: some ParameterSummary { Summary("Set \(\.$side) bed power to \(\.$enabled)") }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await PodActions.client().post("deviceStatus", body: [side.rawValue: ["isOn": enabled]])
        return .result(dialog: "Your bed power command was sent.")
    }
}
