import AppIntents

struct SyncHealthIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Apple Health"
    static let description = IntentDescription("Sync the last thirty days for your personal Health side, saved in sleepypod Settings.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static var parameterSummary: some ParameterSummary { Summary("Sync the last 30 days for my linked Health side") }
    @Dependency(default: NativePodActionBridge.unavailable) var nativeActions: NativePodActionBridge
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let count: Int
        if AppMode.isCore { count = try await nativeActions.syncHealth() }
        else {
            guard let saved = try await HealthSyncService.shared.synchronize() else { throw PodError.message("Health sync did not finish. Review Apple Health settings in the app.") }
            count = saved
        }
        return .result(value: count, dialog: "Wrote or updated \(count) Apple Health samples for your linked side.")
    }
}
