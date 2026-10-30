#if DEBUG
import Foundation
import FreeSleepKit

/// Synthetic recording checks use no Pod, owner transport, credentials or Health data.
@MainActor enum PersonalHistoryPreview {
    static func make() -> HouseholdWorkspace? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--history-fixture"), arguments.indices.contains(index + 1) else { return nil }
        do {
            let mode = arguments[index + 1]
            guard let url = Bundle.main.url(forResource: "household-preparation-v1", withExtension: "json"),
                  let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                  var object = fixture["ownerSession"] as? [String: Any] else { throw HouseholdFailure.invalid }
            var capabilities = object["capabilities"] as? [String: Any] ?? [:]
            capabilities["personalHistory"] = mode != "disabled"; capabilities["personalControls"] = false
            capabilities["personalRoutinePublication"] = false; capabilities["arrangementReview"] = false
            object["capabilities"] = capabilities
            let session = try JSONDecoder().decode(HouseholdSession.self, from: JSONSerialization.data(withJSONObject: object))
            let record = HouseholdConnectionRecord(id: UUID(), endpoint: URL(string: "https://recordings-preview.invalid")!, deviceSecret: String(repeating: "A", count: 43), identity: session)
            let vault = PersonalHistoryPreviewVault(state: .init(connections: [record], selected: record.id))
            let defaults = UserDefaults(suiteName: "personal-history-preview")!
            defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
            let server = PersonalHistoryPreviewServer(account: session, mode: mode)
            return HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in server }, historyClient: { _ in server }, capability: { false }, ownerEndpoint: { nil }, ownerKey: { _ in "" })
        } catch { return nil }
    }
}
#endif
