import SwiftUI
import AppIntents
import BackgroundTasks

public enum UnifiedRuntime {
    @MainActor public static func initialize() {
        NativeModelClient.configureSDK()
        FreeSleepShortcuts.updateAppShortcutParameters()
        if AppMode.isCore { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: HealthBackgroundScheduler.identifier) }
    }
    @MainActor public static func refreshHealth() async {
        guard !AppMode.isDemo, !PersonalWorkspaceBoundary.isActive else { return }
        if !AppMode.isCore { await HealthSyncService.shared.refreshOnActivation() }
        await IntelligenceWorkspace.shared.refreshOnActivation()
    }
    @MainActor public static func backgroundHealth() async {
        guard !AppMode.isDemo, !AppMode.isCore, !PersonalWorkspaceBoundary.isActive else { return }
        await HealthSyncService.shared.runBackground()
    }
    @MainActor public static func suspendPersonalBackgroundWork() { HealthSyncService.shared.cancel(); IntelligenceWorkspace.shared.cancel() }
    public static func savedKey(for address: String) -> String { TokenStore.read(for: address) }
    public static func validatedEndpoint(_ address: String) throws -> URL { try ConnectionEndpoint.url(address) }
    @MainActor public static func configure(address: String, token: String, core: Bool) throws {
        let normalized = try ConnectionEndpoint.url(address).absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        try TokenStore.save(token, for: normalized)
        UserDefaults.standard.set(normalized, forKey: "podURL")
        UserDefaults.standard.set(core ? "native/v1" : "", forKey: "podNativeAPIPrefix")
    }
}

public struct FreeSleepIntentsPackage: AppIntentsPackage {}
