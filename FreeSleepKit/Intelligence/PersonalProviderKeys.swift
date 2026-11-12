import Foundation
import Security

@MainActor protocol PersonalProviderKeys {
    func read(_ provider: IntelligenceProvider) throws -> String
    func save(_ value: String, for provider: IntelligenceProvider) throws
    func remove(_ provider: IntelligenceProvider) throws
}

/// Personal credentials have a separate service and an immutable account/sleeper namespace.
@MainActor struct PersonalProviderKeychain: PersonalProviderKeys {
    static let service = "com.lucaandrea.freesleep.personal-model-keys.v1"
    let identity: PersonalHealthIdentity

    func query(_ provider: IntelligenceProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: identity.reportScope + "|" + provider.rawValue,
         kSecAttrSynchronizable as String: false]
    }

    func read(_ provider: IntelligenceProvider) throws -> String {
        guard provider.needsKey else { return "" }
        var request = query(provider)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw PersonalReportFailure.storage
        }
        return key
    }

    func save(_ value: String, for provider: IntelligenceProvider) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider.needsKey, (10...4096).contains(value.utf8.count), !value.contains(where: { $0.isWhitespace }) else {
            throw PodError.message("Paste the complete API key without spaces.")
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query(provider) as CFDictionary, attributes as CFDictionary)
        let result = status == errSecItemNotFound
            ? SecItemAdd(query(provider).merging(attributes) { _, replacement in replacement } as CFDictionary, nil) : status
        guard result == errSecSuccess else { throw PersonalReportFailure.storage }
    }

    func remove(_ provider: IntelligenceProvider) throws { try Self.delete(query(provider)) }
    func removeAll() throws { for provider in IntelligenceProvider.allCases where provider.needsKey { try remove(provider) } }
    static func eraseAll() throws {
        try delete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                    kSecAttrSynchronizable as String: false])
    }
    private static func delete(_ query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PersonalReportFailure.storage }
    }
}
