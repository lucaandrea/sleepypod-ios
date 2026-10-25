import SwiftUI

@main
struct FreeSleepApp: App {
    init() { NativeModelClient.configureSDK() }
    @State private var model = AppModel()
    @State private var health = HealthSyncService.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environment(model).environment(health).tint(SleepTheme.accent)
                .task(id: scenePhase) {
                    if scenePhase == .active {
                        await health.refreshOnActivation()
                        await IntelligenceWorkspace.shared.refreshOnActivation()
                    }
                    if scenePhase == .background { health.scheduleBackground() }
                }
        }
        .backgroundTask(.appRefresh(HealthBackgroundScheduler.identifier)) {
            await HealthSyncService.shared.runBackground()
        }
    }
}
