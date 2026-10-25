import Foundation
import Security

enum ProviderKeyStore {
    private static func query(_ provider: IntelligenceProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.lucaandrea.freesleep.model-keys",
         kSecAttrAccount as String: provider.rawValue,
         kSecAttrSynchronizable as String: false]
    }
    static func read(_ provider: IntelligenceProvider) throws -> String {
        guard provider.needsKey else { return "" }
        var search = query(provider)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data else {
            throw PodError.message("Unlock your iPhone to access your saved model key.")
        }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ raw: String, for provider: IntelligenceProvider) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider.needsKey, (10...4096).contains(key.count), !key.contains(where: { $0.isWhitespace }) else {
            throw PodError.message("Paste the complete API key without spaces.")
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query(provider) as CFDictionary, attributes as CFDictionary)
        let saved = status == errSecItemNotFound
            ? SecItemAdd(query(provider).merging(attributes) { _, value in value } as CFDictionary, nil) : status
        guard saved == errSecSuccess else { throw PodError.message("The API key could not be saved to Keychain.") }
    }
    static func remove(_ provider: IntelligenceProvider) throws {
        let status = SecItemDelete(query(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PodError.message("The API key could not be removed from Keychain.")
        }
    }
}
