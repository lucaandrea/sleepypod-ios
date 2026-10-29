#if DEBUG
import Foundation
import FreeSleepKit

/// Simulator-only fixture. It has no network client, owner key or persistent credentials.
@MainActor enum HouseholdPreview {
    static func make() -> HouseholdWorkspace? {
        guard ProcessInfo.processInfo.arguments.contains("--household-fixture") else { return nil }
        do {
            let url = Bundle.main.url(forResource: "household-preparation-v1", withExtension: "json")!
            guard let values = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { return nil }
            let fixture = try values.mapValues { try JSONSerialization.data(withJSONObject: $0) }
            let session = try JSONDecoder().decode(HouseholdSession.self, from: fixture["memberSession"]!)
            let record = HouseholdConnectionRecord(id: UUID(), endpoint: URL(string: "https://preview.invalid")!, deviceSecret: String(repeating: "A", count: 43), identity: session)
            let vault = HouseholdPreviewVault(state: .init(connections: [record], selected: record.id))
            let defaults = UserDefaults(suiteName: "household-preview")!
            defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
            let client = HouseholdPreviewClient(fixture: fixture)
            return HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in client }, capability: { false }, ownerEndpoint: { nil }, ownerKey: { _ in "" })
        } catch { return nil }
    }
}
@MainActor private final class HouseholdPreviewVault: HouseholdVault {
    var state: HouseholdVaultState
    init(state: HouseholdVaultState) { self.state = state }
    func load() throws -> HouseholdVaultState { state }
    func save(_ state: HouseholdVaultState) throws { self.state = state }
}
private struct HouseholdPreviewClient: HouseholdTransport {
    let fixture: [String: Data]
    func send(path: String, method: String, token: String?, body: Data?) async throws -> Data {
        guard method == "GET" else { throw HouseholdFailure.unavailable }
        let key = path == "household/session" ? "memberSession" : path.split(separator: "/").last.map(String.init) ?? ""
        guard let data = fixture[key] else { throw HouseholdFailure.unavailable }
        return data
    }
}
#endif
