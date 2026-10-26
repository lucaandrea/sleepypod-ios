import Foundation

struct HomeKitBridgeStatus: Decodable, Sendable, Equatable {
    let enabled: Bool
    let running: Bool
    let transitioning: Bool?
    let pincode: String?
    let setupId: String?
    let setupURI: String?
    let qrDataUrl: String?
    let pairedControllers: [String]
    var stateLabel: String {
        if transitioning == true { return "Changing…" }
        return enabled ? (running ? "Running" : "Starting") : "Off"
    }
    var formattedCode: String? {
        guard let pincode else { return nil }
        let digits = pincode.filter(\.isNumber)
        guard digits.count == 8 else { return nil }
        return "\(digits.prefix(3))-\(digits.dropFirst(3).prefix(2))-\(digits.suffix(3))"
    }
}

struct MQTTSettings: Decodable, Sendable, Equatable {
    let enabled: Bool
    let url: String?
    let username: String?
    let passwordIsSet: Bool
    let topicPrefix: String
    let haDiscovery: Bool
    let tlsEnabled: Bool
    let sources: [String: String]
    func sourceLabel(_ field: String) -> String {
        switch sources[field] {
        case "db": "Saved on Pod"
        case "env": "Pod environment"
        case "default": "Default"
        default: "Source unavailable"
        }
    }
}

struct MQTTBridgeStatus: Decodable, Sendable {
    let runState: String
    let connected: Bool
    let commandsEnabled: Bool?
    let lastError: String?
    let deviceId: String
    let topicPrefix: String?
    let messagesPublished: Int
    let lastPublishAt: String?
    var stateLabel: String {
        switch runState {
        case "stopped": "Stopped"
        case "starting": "Starting"
        case "reconnecting": "Reconnecting"
        case "errored": "Connection error"
        default: connected ? "Connected" : "Disconnected"
        }
    }
    var controlDescription: String {
        guard let commandsEnabled else { return "The Pod has not reported whether MQTT bed control is enabled." }
        return commandsEnabled
            ? "Bed control through MQTT is enabled on this Pod."
            : "This bridge publishes telemetry. Bed control through MQTT is disabled on the Pod."
    }
}

struct MQTTSettingsPatch: Encodable, Sendable {
    var enabled: Bool?
    var url: String?
    var username: String?
    var password: String?
    var topicPrefix: String?
    var haDiscovery: Bool?
    var tlsEnabled: Bool?
    var isEmpty: Bool {
        enabled == nil && url == nil && username == nil && password == nil && topicPrefix == nil && haDiscovery == nil && tlsEnabled == nil
    }
}
struct MQTTConnectionTest: Encodable, Sendable, Equatable {
    let url: String
    let username: String?
    let password: String?
    let tlsEnabled: Bool
}
struct MQTTTestResult: Decodable, Sendable { let ok: Bool; let error: String? }

struct MQTTSettingsDraft: Equatable, Sendable {
    var enabled: Bool
    var url: String
    var username: String
    var password = ""
    var topicPrefix: String
    var haDiscovery: Bool
    var tlsEnabled: Bool
    init(_ settings: MQTTSettings) {
        enabled = settings.enabled; url = settings.url ?? ""; username = settings.username ?? ""
        topicPrefix = settings.topicPrefix; haDiscovery = settings.haDiscovery; tlsEnabled = settings.tlsEnabled
    }
    var brokerURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }
    var brokerIssue: String? {
        guard !brokerURL.isEmpty else { return "Enter a broker URL." }
        guard let parsed = URLComponents(string: brokerURL), let scheme = parsed.scheme?.lowercased(),
              ["mqtt", "mqtts", "ws", "wss"].contains(scheme), let host = parsed.host, !host.isEmpty else {
            return "Use a complete mqtt://, mqtts://, ws:// or wss:// broker URL."
        }
        guard parsed.user == nil, parsed.password == nil else { return "Enter credentials in the username and password fields, outside the broker URL." }
        guard parsed.fragment == nil else { return "Remove the fragment from the broker URL." }
        if tlsEnabled && !["mqtts", "wss"].contains(scheme) { return "TLS requires mqtts:// or wss:// in the broker URL." }
        return nil
    }
    var topicIssue: String? {
        let topic = topicPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return topic.range(of: "^[a-zA-Z0-9_/-]{1,64}$", options: .regularExpression) == nil
            ? "Use 1–64 letters, digits, underscores, slashes or hyphens for the topic prefix." : nil
    }
    var testRequest: MQTTConnectionTest {
        .init(url: brokerURL, username: username.trimmingCharacters(in: .whitespacesAndNewlines),
              password: password.isEmpty ? nil : password, tlsEnabled: tlsEnabled)
    }
    // Only changed fields are written, preserving environment/default provenance and saved secrets.
    func patch(comparedTo settings: MQTTSettings) -> MQTTSettingsPatch {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let topic = topicPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(enabled: enabled == settings.enabled ? nil : enabled,
                     url: brokerURL.isEmpty || brokerURL == settings.url ? nil : brokerURL,
                     username: user == (settings.username ?? "") ? nil : user,
                     password: password.isEmpty ? nil : password,
                     topicPrefix: topic == settings.topicPrefix ? nil : topic,
                     haDiscovery: haDiscovery == settings.haDiscovery ? nil : haDiscovery,
                     tlsEnabled: tlsEnabled == settings.tlsEnabled ? nil : tlsEnabled)
    }
    func safeMessage(_ message: String) -> String {
        password.isEmpty ? message : message.replacingOccurrences(of: password, with: "••••")
    }
}
