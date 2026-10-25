import AppIntents
import Foundation

struct SleepSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Get sleep routine summary"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Side", default: .left) var side: BedSide
    static var parameterSummary: some ParameterSummary { Summary("Get the \(\.$side) bed presence summary") }
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let analytics: SleepAnalytics = try await PodActions.client().get("analytics", query: [URLQueryItem(name: "side", value: side.rawValue)])
        let summary = "Recent bed presence: \(SleepAnalytics.duration(analytics.summary.averageOccupiedMinutes)). "
            + "\(analytics.summary.recordedNights) recorded nights. Presence is not measured sleep."
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}
