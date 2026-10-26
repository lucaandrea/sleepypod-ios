import AppIntents

struct GetNextAlarmIntent: AppIntent {
    static let title: LocalizedStringResource = "Get next bed alarm"
    static let description = IntentDescription("Read the next vibration alarm, its date and the Pod timezone for one side.")
    @Parameter(title: "Side", default: .left) var side: BedSide
    static var parameterSummary: some ParameterSummary { Summary("Get the next \(\.$side) bed alarm") }
    @Dependency(default: NativePodActionBridge.unavailable) var nativeActions: NativePodActionBridge
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        if AppMode.isCore {
            let summary = try await nativeActions.message(.nextAlarm(side: side.rawValue))
            return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
        }
        let preview = try await PodActions.nextAlarm(side: side)
        let summary = "\(side.rawValue.capitalized) side: \(preview.title). \(preview.detail)"
        return .result(value: summary, dialog: "\(summary)")
    }
}

struct ChangeNextAlarmIntent: AppIntent {
    static let title: LocalizedStringResource = "Change next bed alarm"
    static let description = IntentDescription("Change one upcoming alarm on its existing date. Use 24-hour HH:mm in the Pod timezone. The weekly routine stays unchanged.")
    @Parameter(title: "Side", default: .left) var side: BedSide
    @Parameter(title: "Time (HH:mm)") var time: String
    static var parameterSummary: some ParameterSummary { Summary("Change \(\.$side) next alarm to \(\.$time)") }
    @Dependency(default: NativePodActionBridge.unavailable) var nativeActions: NativePodActionBridge
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if AppMode.isCore { return .result(dialog: IntentDialog(stringLiteral: try await nativeActions.message(.changeAlarm(side: side.rawValue, action: "time", time: time)))) }
        let preview = try await PodActions.changeAlarm(side: side, action: .time, time: time)
        return .result(dialog: "\(side.rawValue.capitalized) alarm saved for \(preview.title). \(preview.detail). Vibration requires this side to be on.")
    }
}

struct SkipNextAlarmIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip next bed alarm"
    static let description = IntentDescription("Skip the next vibration alarm once, keeping the weekly routine.")
    @Parameter(title: "Side", default: .left) var side: BedSide
    static var parameterSummary: some ParameterSummary { Summary("Skip the next \(\.$side) bed alarm once") }
    @Dependency(default: NativePodActionBridge.unavailable) var nativeActions: NativePodActionBridge
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if AppMode.isCore { return .result(dialog: IntentDialog(stringLiteral: try await nativeActions.message(.changeAlarm(side: side.rawValue, action: "skip", time: nil)))) }
        _ = try await PodActions.changeAlarm(side: side, action: .disable)
        return .result(dialog: "The next \(side.rawValue) alarm is skipped. Your weekly routine is unchanged.")
    }
}

struct RestoreAlarmRoutineIntent: AppIntent {
    static let title: LocalizedStringResource = "Restore bed alarm routine"
    static let description = IntentDescription("Clear the current one-time alarm change or skip for one side.")
    @Parameter(title: "Side", default: .left) var side: BedSide
    static var parameterSummary: some ParameterSummary { Summary("Restore the \(\.$side) alarm routine") }
    @Dependency(default: NativePodActionBridge.unavailable) var nativeActions: NativePodActionBridge
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if AppMode.isCore { return .result(dialog: IntentDialog(stringLiteral: try await nativeActions.message(.changeAlarm(side: side.rawValue, action: "restore", time: nil)))) }
        let preview = try await PodActions.changeAlarm(side: side, action: .restore)
        return .result(dialog: "\(side.rawValue.capitalized) alarm routine restored. \(preview.title). \(preview.detail)")
    }
}
