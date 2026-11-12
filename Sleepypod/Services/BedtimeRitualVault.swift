import CryptoKit
import Foundation
import Security

/// Settings and uncertain handoffs are device-only and scoped to the authenticated account.
@MainActor struct BedtimeRitualVault: BedtimeRitualStoring {
    var service = "com.lucaandrea.freesleep.bedtime-ritual.v1"
    private func query(_ scope: String) throws -> [String: Any] {
        guard BedtimeRitualClock.scope(scope) else { throw BedtimeRitualFailure.invalid }
        let digest = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: digest, kSecAttrSynchronizable as String: false]
    }
    func load(scope: String) throws -> BedtimeRitualSavedState? {
        var request = try query(scope)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 16_384 else { throw BedtimeRitualFailure.storage }
        do {
            let state = try JSONDecoder().decode(BedtimeRitualSavedState.self, from: data)
            try state.validate(scope: scope)
            return state
        } catch { throw BedtimeRitualFailure.storage }
    }
    func save(_ state: BedtimeRitualSavedState) throws {
        try state.validate(scope: state.scope)
        let data = try JSONEncoder().encode(state)
        guard data.count <= 16_384 else { throw BedtimeRitualFailure.storage }
        let request = try query(state.scope)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                       kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insertion = request.merging(attributes) { _, new in new }
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else { throw BedtimeRitualFailure.storage }
        } else if status != errSecSuccess { throw BedtimeRitualFailure.storage }
    }
    func remove(scope: String) throws {
        let status = SecItemDelete(try query(scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BedtimeRitualFailure.storage }
    }
}
