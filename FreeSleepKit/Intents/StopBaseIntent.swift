import AppIntents

struct StopBaseIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop bed movement"
    static var parameterSummary: some ParameterSummary { Summary("Send Stop to the whole bed") }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await PodActions.client().action("base/stop")
        return .result(dialog: "Stop was sent to your base.")
    }
}
