import Foundation

struct ArchivePushConfiguration: Codable, Sendable, Equatable {
    var enabled: Bool
    var host: String
    var remoteUser: String
    var remotePath: String
    var port: Int
    var identity: String
    var include: [String]
}
struct ArchivePushSnapshot: Decodable, Sendable {
    let config: ArchivePushConfiguration
    let publicKey: String?
}
struct ArchivePushKeyReceipt: Decodable, Sendable { let publicKey: String; let generated: Bool }
struct ArchivePushTestReceipt: Decodable, Sendable { let ok: Bool; let message: String }

struct ArchivePushDraft: Equatable, Sendable {
    var enabled: Bool
    var host: String
    var remoteUser: String
    var remotePath: String
    var port: String
    var includeRaw: Bool
    var includeDatabase: Bool
    let identity: String
    init(_ config: ArchivePushConfiguration) {
        enabled = config.enabled; host = config.host; remoteUser = config.remoteUser; remotePath = config.remotePath
        port = String(config.port); includeRaw = config.include.contains("raw"); includeDatabase = config.include.contains("db")
        identity = config.identity
    }
    var issue: String? {
        guard let port = Int(port), (1...65535).contains(port) else { return "Enter a port from 1 to 65535." }
        guard includeRaw || includeDatabase else { return "Choose at least one dataset to archive." }
        if [host, remoteUser, remotePath, identity].contains(where: { $0.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) }) {
            return "Connection fields cannot contain line breaks."
        }
        if enabled && [host, remoteUser, remotePath].contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return "Enter the destination host, user and path before enabling nightly push."
        }
        return nil
    }
    var configuration: ArchivePushConfiguration? {
        guard issue == nil, let port = Int(port) else { return nil }
        return .init(enabled: enabled, host: host.trimmingCharacters(in: .whitespaces),
                     remoteUser: remoteUser.trimmingCharacters(in: .whitespaces), remotePath: remotePath.trimmingCharacters(in: .whitespaces),
                     port: port, identity: identity, include: (includeRaw ? ["raw"] : []) + (includeDatabase ? ["db"] : []))
    }
}
