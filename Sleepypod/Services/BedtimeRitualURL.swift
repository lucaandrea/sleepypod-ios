import Foundation

/// The URL contains the requested audio settings and a one-use return token, never Pod credentials or Health data.
enum BedtimeRitualURL {
    static let callbackScheme = "sleepypod-bedtime"
    struct Input: Codable, Equatable {
        let version: Int
        let requestId: String
        let mode: BedtimeRitualPlan.Mode
        let speakerName: String
        let volumePercent: Int
        let durationMinutes: Int
        let action: BedtimeRitualAttempt.Action
    }
    static func launch(_ attempt: BedtimeRitualAttempt) throws -> URL {
        try attempt.validate()
        let plan = attempt.plan
        let input = Input(version: 1, requestId: attempt.requestId.uuidString.lowercased(), mode: plan.mode,
                          speakerName: plan.speakerName, volumePercent: plan.volumePercent,
                          durationMinutes: plan.durationMinutes, action: attempt.action)
        let data = try JSONEncoder().encode(input)
        guard let text = String(data: data, encoding: .utf8) else { throw BedtimeRitualFailure.invalid }
        var components = URLComponents()
        components.scheme = "shortcuts"; components.host = "x-callback-url"; components.path = "/run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: attempt.action == .start ? plan.startShortcut : plan.pauseShortcut),
            URLQueryItem(name: "input", value: "text"), URLQueryItem(name: "text", value: text)]
        for (name, result) in [("x-success", "completed"), ("x-cancel", "cancelled"), ("x-error", "failed")] {
            components.queryItems?.append(.init(name: name, value: try callback(attempt, result: result).absoluteString))
        }
        guard let url = components.url else { throw BedtimeRitualFailure.invalid }
        return url
    }
    static func callback(_ attempt: BedtimeRitualAttempt, result: String) throws -> URL {
        var components = URLComponents()
        components.scheme = callbackScheme; components.host = "return"; components.path = "/\(result)"
        components.queryItems = [.init(name: "request", value: attempt.requestId.uuidString.lowercased()),
                                 .init(name: "nonce", value: attempt.nonce.uuidString.lowercased())]
        guard let url = components.url else { throw BedtimeRitualFailure.invalid }
        return url
    }
    /// Provider output is deliberately ignored. A callback is only a Shortcut's reported outcome.
    static func outcome(_ url: URL, attempt: BedtimeRitualAttempt) -> BedtimeRitualAttempt.Outcome? {
        guard url.absoluteString.utf8.count <= 8192, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == callbackScheme, parts.host == "return", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.fragment == nil else { return nil }
        let outcome: BedtimeRitualAttempt.Outcome
        let allowed: Set<String>
        switch parts.path {
        case "/completed": outcome = .shortcutCompleted; allowed = ["request", "nonce", "result"]
        case "/cancelled": outcome = .shortcutCancelled; allowed = ["request", "nonce"]
        case "/failed": outcome = .shortcutFailed; allowed = ["request", "nonce", "errorMessage", "errorCode"]
        default: return nil
        }
        let items = parts.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count, Set(items.map(\.name)).isSubset(of: allowed),
              items.first(where: { $0.name == "request" })?.value == attempt.requestId.uuidString.lowercased(),
              items.first(where: { $0.name == "nonce" })?.value == attempt.nonce.uuidString.lowercased() else { return nil }
        return outcome
    }
}
