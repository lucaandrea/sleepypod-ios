import AppIntents

struct SyncHealthIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Apple Health"
    static let description = IntentDescription("Sync the last thirty days for your personal Health side, saved in sleepypod Settings.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static var parameterSummary: some ParameterSummary { Summary("Sync the last 30 days for my linked Health side") }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let count = try await HealthSyncService.shared.synchronize() ?? 0
        return .result(value: count, dialog: "Wrote or updated \(count) Apple Health samples for your linked side.")
    }
}
