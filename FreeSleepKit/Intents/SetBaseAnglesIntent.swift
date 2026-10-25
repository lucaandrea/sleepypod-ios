import AppIntents

struct SetBaseAnglesIntent: AppIntent {
    static let title: LocalizedStringResource = "Set head and feet angles"
    static let description = IntentDescription("Move the entire bed to specific head and feet angles.")
    @Parameter(title: "Head degrees", default: 0) var head: Int
    @Parameter(title: "Feet degrees", default: 0) var feet: Int
    static var parameterSummary: some ParameterSummary { Summary("Move the whole bed to head \(\.$head)° and feet \(\.$feet)°") }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard (0...60).contains(head), (0...45).contains(feet) else { throw PodError.message("Head must be 0–60° and feet 0–45°.") }
        try await PodActions.client().post("base/position", body: ["head": head, "feet": feet, "speed": 50])
        return .result(dialog: "The position command was sent to your base.")
    }
}
