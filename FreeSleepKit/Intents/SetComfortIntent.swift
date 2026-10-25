import AppIntents

struct SetComfortIntent: AppIntent {
    static let title: LocalizedStringResource = "Set adaptive comfort"
    static let description = IntentDescription("Choose whether feedback can adjust your scheduled temperature. Your saved comfort limits are preserved.")
    @Parameter(title: "Side", default: .left) var side: BedSide
    @Parameter(title: "Mode", default: .preview) var mode: ComfortMode
    static var parameterSummary: some ParameterSummary { Summary("Set \(\.$side) adaptive comfort to \(\.$mode)") }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await PodActions.setComfort(side: side, mode: mode)
        return .result(dialog: "Adaptive comfort is set to \(mode.rawValue) for your \(side.rawValue) side.")
    }
}
