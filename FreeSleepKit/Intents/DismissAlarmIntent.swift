import AppIntents

struct DismissAlarmIntent: AppIntent {
    static let title: LocalizedStringResource = "Dismiss bed alarm"
    @Parameter(title: "Side", default: .left) var side: BedSide
    static var parameterSummary: some ParameterSummary { Summary("Dismiss the \(\.$side) bed alarm") }
    @Dependency(default: NativePodActionBridge.unavailable) var nativeActions: NativePodActionBridge
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if AppMode.isCore { return .result(dialog: IntentDialog(stringLiteral: try await nativeActions.message(.dismissAlarm(side: side.rawValue)))) }
        try await PodActions.client().post("deviceStatus", body: [side.rawValue: ["isAlarmVibrating": false]])
        return .result(dialog: "The alarm dismissal command was sent to your \(side.rawValue) side.")
    }
}
