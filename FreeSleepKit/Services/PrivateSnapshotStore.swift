import CryptoKit
import Foundation
import Security

/// Authenticated, device-local snapshots. Scope is authenticated as well as hashed
/// into the filename, so moving a file between accounts cannot make it readable.
public struct PrivateSnapshotStore {
    private let directory: URL
    private let namespace: String
    private let encryptionKey: () throws -> SymmetricKey

    public init(directory: URL = URL.applicationSupportDirectory.appending(path: "PrivateSnapshots"),
                namespace: String, encryptionKey: (() throws -> SymmetricKey)? = nil) {
        self.directory = directory
        self.namespace = namespace
        self.encryptionKey = encryptionKey ?? { try SnapshotEncryptionKey.load(namespace: namespace) }
    }

    public func read<Value: Decodable>(_ type: Value.Type, scope: String) throws -> Value? {
        let file = location(scope)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: file))
        let plaintext = try AES.GCM.open(box, using: encryptionKey(), authenticating: context(scope))
        return try JSONDecoder().decode(type, from: plaintext)
    }

    public func write<Value: Encodable>(_ value: Value, scope: String) throws {
        let plaintext = try JSONEncoder().encode(value)
        let box = try AES.GCM.seal(plaintext, using: encryptionKey(), authenticating: context(scope))
        guard let ciphertext = box.combined else { throw SnapshotFailure.storage }
        var folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try folder.setResourceValues(resources)
        try ciphertext.write(to: location(scope), options: [.atomic, .completeFileProtection])
    }

    public func remove(scope: String) throws {
        let file = location(scope)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    private func context(_ scope: String) -> Data { Data("v1|\(namespace)|\(scope)".utf8) }
    private func location(_ scope: String) -> URL {
        let identifier = SHA256.hash(data: context(scope)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: identifier + ".sealed")
    }
}

private enum SnapshotFailure: Error { case storage, keychain(OSStatus) }

private enum SnapshotEncryptionKey {
    static func load(namespace: String) throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.lucaandrea.freesleep.snapshots",
            kSecAttrAccount as String: namespace]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else { throw SnapshotFailure.keychain(status) }
        let key = SymmetricKey(size: .bits256)
        var item = query
        item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        if added == errSecDuplicateItem { return try load(namespace: namespace) }
        guard added == errSecSuccess else { throw SnapshotFailure.keychain(added) }
        return key
    }
}
