import AppIntents

struct SetAwayModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Away mode"
    static let description = IntentDescription("Pause or resume scheduled routines for one bed side.")
    @Parameter(title: "Side", default: .left) var side: BedSide
    @Parameter(title: "Away", default: true) var away: Bool
    static var parameterSummary: some ParameterSummary { Summary("Set \(\.$side) Away mode to \(\.$away)") }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await PodActions.client().post("settings", body: [side.rawValue: ["awayMode": away]])
        return .result(dialog: "Away mode is \(away ? "on" : "off") for your \(side.rawValue) side.")
    }
}
