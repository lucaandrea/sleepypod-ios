import SwiftUI
import AppIntents

public enum UnifiedRuntime {
    @MainActor public static func initialize() { NativeModelClient.configureSDK() }
    @MainActor public static func refreshHealth() async {
        guard !AppMode.isDemo else { return }
        await HealthSyncService.shared.refreshOnActivation()
        await IntelligenceWorkspace.shared.refreshOnActivation()
    }
    @MainActor public static func backgroundHealth() async {
        guard !AppMode.isDemo else { return }
        await HealthSyncService.shared.runBackground()
    }
    public static func savedKey(for address: String) -> String { TokenStore.read(for: address) }
    @MainActor public static func configure(address: String, token: String, core: Bool) throws {
        let normalized = try ConnectionEndpoint.url(address).absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        try TokenStore.save(token, for: normalized)
        UserDefaults.standard.set(normalized, forKey: "podURL")
        UserDefaults.standard.set(core ? "native/v1" : "", forKey: "podNativeAPIPrefix")
    }
}

public struct FreeSleepIntentsPackage: AppIntentsPackage {}
