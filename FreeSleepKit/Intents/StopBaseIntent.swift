import AppIntents

struct StopBaseIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop bed movement"
    static var parameterSummary: some ParameterSummary { Summary("Send Stop to the whole bed") }
    @Dependency(default: NativePodActionBridge.unavailable) var nativeActions: NativePodActionBridge
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if AppMode.isCore { return .result(dialog: IntentDialog(stringLiteral: try await nativeActions.message(.stopBase))) }
        try await PodActions.client().action("base/stop")
        return .result(dialog: "Stop was sent to your base.")
    }
}
