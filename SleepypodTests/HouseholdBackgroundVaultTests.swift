import Security
import XCTest
@testable import Sleepypod

/// Exercise real Keychain item migration in an isolated namespace; physical lock behavior is a separate device check.
@MainActor final class HouseholdBackgroundVaultTests: XCTestCase {
    private let service = "sleepypod-vault-tests.\(UUID().uuidString)"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "connections.v1"]
    }
    private func attributes() throws -> [String: Any] {
        var lookup = query; lookup[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(lookup as CFDictionary, &result), errSecSuccess)
        return try XCTUnwrap(result as? [String: Any])
    }
    private func legacy(_ data: Data) {
        var value = query; value[kSecValueData as String] = data
        value[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        XCTAssertEqual(SecItemAdd(value as CFDictionary, nil), errSecSuccess)
    }
    func testExistingReadableAccountVaultMigratesWithoutReplacingItsContents() throws {
        defer { SecItemDelete(query as CFDictionary) }
        let session = try PersonalControlFixtures.session(for: PersonalControlFixtures.bed())
        let record = HouseholdConnectionRecord(id: UUID(), endpoint: URL(string: "https://example.invalid")!,
            deviceSecret: String(repeating: "A", count: 43), identity: session)
        let state = HouseholdVaultState(connections: [record], selected: record.id)
        legacy(try JSONEncoder().encode(state))
        let loaded = try HouseholdKeychainVault(service: service).load()
        XCTAssertEqual(loaded.selected, state.selected)
        XCTAssertEqual(loaded.connections.first?.deviceSecret, record.deviceSecret)
        XCTAssertEqual(loaded.connections.first?.identity, session)
        XCTAssertEqual(try attributes()[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }
    func testMalformedLegacyVaultDoesNotMigrateOrBecomeAnEmptyAccount() throws {
        defer { SecItemDelete(query as CFDictionary) }
        legacy(Data("not a vault".utf8))
        XCTAssertThrowsError(try HouseholdKeychainVault(service: service).load())
        XCTAssertEqual(try attributes()[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }
    func testNewControlVaultSupportsBackgroundAccessOnlyOnThisDevice() throws {
        defer { SecItemDelete(query as CFDictionary) }
        let vault = HouseholdKeychainVault(service: service)
        try vault.save(.init())
        XCTAssertTrue(try vault.load().connections.isEmpty)
        XCTAssertEqual(try attributes()[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }
}
