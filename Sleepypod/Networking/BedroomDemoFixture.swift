#if DEBUG
import Foundation

/// Explicit UI-test fixture only. Never discovers real accessories or publishes a report.
actor BedroomDemoFixtureClient: BedroomServing {
    private let data: Data
    init() throws {
        guard let url = Bundle.main.url(forResource: "bedroom-context-core", withExtension: "json") else { throw BedroomStatus.issue }
        data = try Data(contentsOf: url)
    }
    func status() throws -> BedroomStatus {
        guard let original = try JSONSerialization.jsonObject(with: data) as? [String: Any], let generated = original["generatedAt"] as? Int64 else { throw BedroomStatus.issue }
        let shift = Int64(Date.now.timeIntervalSince1970 * 1000) - generated
        let timestamps: Set<String> = ["generatedAt", "observedAt", "measuredAt", "receivedAt", "expiresAt"]
        func shiftClocks(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                return dictionary.reduce(into: [String: Any]()) { output, pair in
                    if timestamps.contains(pair.key), let timestamp = pair.value as? Int64 { output[pair.key] = timestamp + shift }
                    else { output[pair.key] = shiftClocks(pair.value) }
                }
            }
            if let array = value as? [Any] { return array.map(shiftClocks) }
            return value
        }
        return try JSONDecoder().decode(BedroomStatus.self, from: JSONSerialization.data(withJSONObject: shiftClocks(original)))
    }
    func configure(_ config: BedroomConfiguration, expectedRevision: Int64) throws -> BedroomVersion { throw BedroomStatus.issue }
}
#endif
