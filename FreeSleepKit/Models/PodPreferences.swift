import Foundation

struct PodPreferences: Codable, Equatable, Sendable {
    struct Side: Codable, Equatable, Sendable { var name: String; var awayMode: Bool }
    struct Daily: Codable, Equatable, Sendable { var enabled: Bool; var time: String }
    var timeZone: String
    var temperatureFormat: String
    var left: Side
    var right: Side
    var primePodDaily: Daily
    var rebootDaily: Bool
    var valid: Bool {
        [left.name, right.name].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 20 }
            && primePodDaily.time.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil
            && ["fahrenheit", "celsius"].contains(temperatureFormat)
    }
    var normalized: Self {
        var result = self
        result.left.name = left.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.right.name = right.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
    func settings(podID: String) -> PodSettings {
        .init(id: podID, timeZone: timeZone, temperatureFormat: temperatureFormat,
              left: .init(name: left.name, awayMode: left.awayMode), right: .init(name: right.name, awayMode: right.awayMode))
    }
}
struct PreferencesSnapshot: Codable, Equatable, Sendable {
    var podID: String
    var timeZones: [String]
    var preferences: PodPreferences
}
struct PreferenceChange: Encodable, Sendable {
    var podID: String
    var expected: PodPreferences
    var preferences: PodPreferences
}
struct ServiceHealth: Decodable, Sendable {
    var name: String
    var status: String
    var description: String
    var message: String
    var timestamp: String?
    var label: String { switch status {
    case "not_started": "Not started"
    case "started": "Started"
    case "healthy": "Healthy"
    case "failed": "Failed"
    case "retrying": "Retrying"
    case "restarting": "Restarting"
    default: "Unknown"
    } }
}
struct DeviceDemo: Decodable, Sendable {
    var preferences: PreferencesSnapshot
    var health: [String: ServiceHealth]
    static let shared: Self? = {
        guard let url = Bundle.main.url(forResource: "device-demo", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }()
}
