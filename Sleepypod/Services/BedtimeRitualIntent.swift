import AppIntents
import Observation

/// System entry opens a review. It never starts or pauses audio on its own.
@MainActor @Observable final class BedtimeRitualIntentRoute {
    static let shared = BedtimeRitualIntentRoute()
    private(set) var request: UUID?
    func open() { request = UUID() }
    func consume() -> Bool {
        guard request != nil else { return false }
        request = nil; return true
    }
}

struct OpenBedtimeAudioIntent: AppIntent {
    static let title: LocalizedStringResource = "Open bedtime audio"
    static let description = IntentDescription("Review your Endel bedtime setup and start its saved Shortcut from sleepypod.")
    static var openAppWhenRun: Bool { true }
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @MainActor func perform() async throws -> some IntentResult {
        BedtimeRitualIntentRoute.shared.open()
        return .result()
    }
}
