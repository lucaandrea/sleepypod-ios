import Foundation

protocol HomeKitBridgeClient: Sendable {
    func status() async throws -> HomeKitBridgeStatus
    func setEnabled(_ enabled: Bool) async throws -> HomeKitBridgeStatus
    func resetPairing() async throws -> HomeKitBridgeStatus
}
struct CoreHomeKitBridgeClient: HomeKitBridgeClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient { get throws { guard let transport else { throw APIError.noBaseURL }; return transport } }
    func status() async throws -> HomeKitBridgeStatus { try await client.get("homekit/status") }
    func setEnabled(_ enabled: Bool) async throws -> HomeKitBridgeStatus {
        struct Input: Encodable, Sendable { let enabled: Bool }
        return try await client.post("homekit/enabled", body: Input(enabled: enabled), returning: HomeKitBridgeStatus.self)
    }
    func resetPairing() async throws -> HomeKitBridgeStatus {
        try await client.post("homekit/unpair", body: [String: String](), returning: HomeKitBridgeStatus.self)
    }
}
protocol MQTTSettingsClient: Sendable {
    func settings() async throws -> MQTTSettings
    func status() async throws -> MQTTBridgeStatus
    func save(_ patch: MQTTSettingsPatch) async throws
    func test(_ request: MQTTConnectionTest) async throws -> MQTTTestResult
}
struct CoreMQTTSettingsClient: MQTTSettingsClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient { get throws { guard let transport else { throw APIError.noBaseURL }; return transport } }
    func settings() async throws -> MQTTSettings { try await client.get("mqtt/settings") }
    func status() async throws -> MQTTBridgeStatus { try await client.get("mqtt/status") }
    func save(_ patch: MQTTSettingsPatch) async throws {
        struct Receipt: Decodable, Sendable { let success: Bool }
        let receipt = try await client.patch("mqtt/settings", body: patch, returning: Receipt.self)
        guard receipt.success else { throw APIError.serverError(message: "The Pod did not confirm the settings change.") }
    }
    func test(_ request: MQTTConnectionTest) async throws -> MQTTTestResult {
        try await client.post("mqtt/test-connection", body: request, returning: MQTTTestResult.self)
    }
}

actor DemoHomeKitBridgeClient: HomeKitBridgeClient {
    private var enabled = true
    private var paired = ["Demo Home"]
    func status() -> HomeKitBridgeStatus {
        .init(enabled: enabled, running: enabled, transitioning: false,
              pincode: enabled && paired.isEmpty ? "031-45-154" : nil, setupId: enabled ? "DEMO" : nil,
              setupURI: enabled && paired.isEmpty ? "X-HM://0023ISYWYDEMO" : nil, qrDataUrl: nil, pairedControllers: paired)
    }
    func setEnabled(_ value: Bool) -> HomeKitBridgeStatus { enabled = value; return status() }
    func resetPairing() -> HomeKitBridgeStatus { paired = []; return status() }
}
actor DemoMQTTSettingsClient: MQTTSettingsClient {
    private var value = MQTTSettings(enabled: true, url: "mqtt://broker.example.invalid:1883", username: "sleepypod", passwordIsSet: true,
                                     topicPrefix: "sleepypod", haDiscovery: true, tlsEnabled: false,
                                     sources: ["enabled": "db", "url": "db", "username": "db", "password": "db", "topicPrefix": "default", "haDiscovery": "default", "tlsEnabled": "default"])
    func settings() -> MQTTSettings { value }
    func status() -> MQTTBridgeStatus {
        .init(runState: value.enabled ? "connected" : "stopped", connected: value.enabled, commandsEnabled: false,
              lastError: nil, deviceId: "sleepypod-demo", topicPrefix: value.enabled ? value.topicPrefix : nil,
              messagesPublished: 1840, lastPublishAt: Date.now.addingTimeInterval(-3).ISO8601Format())
    }
    func save(_ patch: MQTTSettingsPatch) {
        var sources = value.sources
        for (key, changed) in [("enabled", patch.enabled != nil), ("url", patch.url != nil), ("username", patch.username != nil),
                               ("password", patch.password != nil), ("topicPrefix", patch.topicPrefix != nil),
                               ("haDiscovery", patch.haDiscovery != nil), ("tlsEnabled", patch.tlsEnabled != nil)] where changed { sources[key] = "db" }
        value = .init(enabled: patch.enabled ?? value.enabled, url: patch.url ?? value.url, username: patch.username ?? value.username,
                      passwordIsSet: patch.password.map { !$0.isEmpty } ?? value.passwordIsSet,
                      topicPrefix: patch.topicPrefix ?? value.topicPrefix, haDiscovery: patch.haDiscovery ?? value.haDiscovery,
                      tlsEnabled: patch.tlsEnabled ?? value.tlsEnabled, sources: sources)
    }
    func test(_ request: MQTTConnectionTest) -> MQTTTestResult { .init(ok: true, error: nil) }
}
