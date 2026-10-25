import AppIntents

struct PrimePodIntent: AppIntent {
    static let title: LocalizedStringResource = "Prime the Pod"
    static let description = IntentDescription("Start a water priming cycle for the whole Pod.")
    static var parameterSummary: some ParameterSummary { Summary("Start a priming cycle for the whole Pod") }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await PodActions.client().post("deviceStatus", body: ["isPriming": true])
        return .result(dialog: "A priming command was sent to your Pod.")
    }
}
