import Foundation

protocol ArchivePushClient: Sendable {
    func settings() async throws -> ArchivePushSnapshot
    func save(_ config: ArchivePushConfiguration) async throws
    func generateKey() async throws -> ArchivePushKeyReceipt
    func test() async throws -> ArchivePushTestReceipt
}
struct CoreArchivePushClient: ArchivePushClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient { get throws { guard let transport else { throw APIError.noBaseURL }; return transport } }
    func settings() async throws -> ArchivePushSnapshot { try await client.get("archive-push/config") }
    func save(_ config: ArchivePushConfiguration) async throws {
        struct Receipt: Decodable, Sendable { let ok: Bool }
        let receipt = try await client.post("archive-push/config", body: config, returning: Receipt.self)
        guard receipt.ok else { throw APIError.serverError(message: "The Pod did not confirm the archive configuration.") }
    }
    func generateKey() async throws -> ArchivePushKeyReceipt {
        try await client.post("archive-push/key", body: [String: String](), returning: ArchivePushKeyReceipt.self)
    }
    func test() async throws -> ArchivePushTestReceipt {
        try await client.post("archive-push/test", body: [String: String](), returning: ArchivePushTestReceipt.self)
    }
}
actor DemoArchivePushClient: ArchivePushClient {
    private var config = ArchivePushConfiguration(enabled: false, host: "storage.example.invalid", remoteUser: "sleepypod",
                                                  remotePath: "/backups/sleepypod", port: 22,
                                                  identity: "/etc/sleepypod/archive-push.id_ed25519", include: ["raw", "db"])
    private var publicKey: String?
    func settings() -> ArchivePushSnapshot { .init(config: config, publicKey: publicKey) }
    func save(_ value: ArchivePushConfiguration) { config = value }
    func generateKey() -> ArchivePushKeyReceipt {
        let generated = publicKey == nil
        // Explicitly synthetic text; demo never creates or exports an SSH identity.
        let key = "DEMO · simulated public key (not a usable SSH key)"
        publicKey = key
        return .init(publicKey: key, generated: generated)
    }
    func test() -> ArchivePushTestReceipt { .init(ok: true, message: "Simulated connection accepted. No archive was transferred.") }
}
