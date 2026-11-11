import Foundation

struct NightExplanationExample: Decodable, Sendable {
    let synthetic: Bool
    let sourceCommit: String
    let now: Double
    let cases: [String: NightExplanation]
    static func load() throws -> Self {
        guard let file = Bundle.main.url(forResource: "night-explanation-example", withExtension: "json") else { throw APIError.invalidResponse(statusCode: 0) }
        let fixture = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard fixture.synthetic, fixture.sourceCommit.count == 40 else { throw APIError.invalidResponse(statusCode: 0) }
        return fixture
    }
}

/// A read-only, clearly labelled practice report with no network or command capability.
struct DemoNightExplanationClient: NightExplanationClient {
    func read(side: Side, wakeDate: String) throws -> NightExplanation {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "uiNightUnavailable") { throw URLError(.notConnectedToInternet) }
        #endif
        let fixture = try NightExplanationExample.load()
        guard let original = fixture.cases[side == .left ? "normal" : "right"],
              let zone = TimeZone(identifier: original.timeZone) else { throw APIError.invalidResponse(statusCode: 0) }
        let now = Date.now
        // Practice uses the latest morning, clips at now, and rejects other selections honestly.
        guard wakeDate == NightExplanation.dateKey(now, timeZone: zone) else { throw APIError.invalidResponse(statusCode: 0) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        guard let end = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now),
              let start = calendar.date(byAdding: .day, value: -1, to: end),
              var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any] else { throw APIError.invalidResponse(statusCode: 0) }
        let startMs = start.timeIntervalSince1970 * 1000, endMs = end.timeIntervalSince1970 * 1000
        let nowMs = floor(now.timeIntervalSince1970 * 1000), offset = startMs - original.start
        object["generatedAt"] = nowMs; object["start"] = startMs; object["end"] = endMs
        object["observedThrough"] = min(nowMs, endMs); object["wakeDate"] = wakeDate
        for (key, clocks, observationKey) in [
            ("events", ["at", "through"], "through"), ("thermal", ["at"], "at"),
            ("room", ["receivedAt", "observedAt", "measuredAt"], "receivedAt")
        ] {
            let rows = object[key] as? [[String: Any]] ?? []
            object[key] = rows.compactMap { row -> [String: Any]? in
                var shifted = row
                for clock in clocks { if let value = row[clock] as? Double { shifted[clock] = value + offset } }
                guard let at = shifted[observationKey] as? Double, at < endMs, at <= nowMs else { return nil }
                return shifted
            }
        }
        let report = try JSONDecoder().decode(NightExplanation.self, from: JSONSerialization.data(withJSONObject: object))
        try report.validate()
        return report
    }
}
