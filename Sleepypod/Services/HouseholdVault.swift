import Foundation
import Security

struct HouseholdPendingRequest: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case setup, join, invitation, revokeInvitation, revokeDevice, preferences, routines }
    let kind: Kind
    let body: Data
    var path: String {
        switch kind {
        case .setup: "household/setup"
        case .join: "household/join"
        case .invitation, .revokeInvitation: "household/invitations"
        case .revokeDevice: "household/devices"
        case .preferences: "me/preferences"
        case .routines: "me/routines"
        }
    }
    var method: String {
        switch kind {
        case .preferences, .routines: "PUT"
        case .revokeInvitation, .revokeDevice: "DELETE"
        default: "POST"
        }
    }
}

struct HouseholdConnectionRecord: Codable, Identifiable, Sendable {
    let id: UUID
    var endpoint: URL
    let deviceSecret: String
    var identity: HouseholdSession?
    var offlineBlocked: Bool?
    var pending: HouseholdPendingRequest?
    var invitationSecrets: [String: String] = [:]
    var draftPreferences: HouseholdPreferences?
    var draftRoutines: [HouseholdRoutine]?
    var draftPreferencesRevision: Int?
    var draftRoutinesRevision: Int?
    var personalControls: [PersonalControlAttempt]?
    var personalPublications: [PersonalRoutineAttempt]?
    var verifiedRoutes: VerifiedPersonalRoutes?
}

struct HouseholdVaultState: Codable {
    var connections: [HouseholdConnectionRecord] = []
    var selected: UUID?
    var controlTombstones: [PersonalControlTombstone]?
    var publicationTombstones: [PersonalRoutineTombstone]?
}

@MainActor protocol HouseholdVault {
    func load() throws -> HouseholdVaultState
    func save(_ state: HouseholdVaultState) throws
}

/// Tokens, invitations, uncertain requests and private drafts never enter UserDefaults or files.
@MainActor struct HouseholdKeychainVault: HouseholdVault {
    private let service: String
    init(service: String = "com.lucaandrea.freesleep.household") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "connections.v1"]
    }
    func load() throws -> HouseholdVaultState {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return .init() }
        guard status == errSecSuccess, let data = result as? Data,
              let state = try? JSONDecoder().decode(HouseholdVaultState.self, from: data) else { throw HouseholdFailure.storage }
        // A live Watch action wakes a locked iPhone. Migrate only a successfully read account vault;
        // Health snapshots and provider keys use their separate, stricter Keychain stores.
        let migrated = SecItemUpdate(query as CFDictionary,
            [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
        guard migrated == errSecSuccess else { throw HouseholdFailure.storage }
        return state
    }
    func save(_ state: HouseholdVaultState) throws {
        let data = try JSONEncoder().encode(state)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, value in value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw HouseholdFailure.storage }
        } else if status != errSecSuccess { throw HouseholdFailure.storage }
    }
    nonisolated static func secret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw HouseholdFailure.storage }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
