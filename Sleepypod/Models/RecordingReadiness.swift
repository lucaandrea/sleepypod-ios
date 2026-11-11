import Foundation

/// Equipment observations have their own expiry; a new HTTP response cannot renew old evidence.
struct RecordingReadiness: Codable, Sendable, Equatable {
    struct Check: Codable, Identifiable, Sendable, Equatable {
        let id: String
        let title: String
        let state: String
        let detail: String
        let nextStep: String?
        let observedAt: Double?
        var statusLabel: String {
            switch state {
            case "ok": "Checked"
            case "attention": "Needs attention"
            default: "Not verified"
            }
        }
    }
    enum Status: Equatable { case ready, attention, unknown, unavailable }
    let apiVersion: Int
    let generatedAt: Double
    let expiresAt: Double
    let state: String
    let summary: String
    let checks: [Check]
    let historicalWindowHours: Int

    static let requiredChecks: Set<String> = [
        "sensor-cap", "sensor-piezo", "sleep-detector", "piezo-processor",
        "database", "recording-database", "storage", "presence-history"
    ]
    var checkedDate: Date { Date(timeIntervalSince1970: generatedAt / 1000) }

    func validate() throws {
        guard apiVersion == 1, historicalWindowHours == 24, validTimestamp(generatedAt),
              validTimestamp(expiresAt), expiresAt <= generatedAt + 60_000,
              checks.count == Self.requiredChecks.count, Set(checks.map(\.id)) == Self.requiredChecks,
              checks.allSatisfy({ $0.observedAt.map(validTimestamp) ?? true }) else {
            throw APIError.serverError(message: "The controller returned an unsupported recording check. Update the controller and try again.")
        }
    }

    func status(at date: Date) -> Status {
        let now = date.timeIntervalSince1970 * 1000
        guard (try? validate()) != nil, now.isFinite, generatedAt <= now,
              generatedAt >= now - 60_000, expiresAt > now else { return .unavailable }
        // Defend the native view even if a future server accidentally extends expiry.
        let current = checks.allSatisfy {
            guard let observed = $0.observedAt else { return $0.state == "unknown" }
            return observed <= now && observed >= now - 60_000
        }
        guard current else { return .unavailable }
        if state == "attention" || checks.contains(where: { $0.state == "attention" }) { return .attention }
        if state == "ready", checks.allSatisfy({ $0.state == "ok" && $0.observedAt != nil }) { return .ready }
        return .unknown
    }
    private func validTimestamp(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= 9_007_199_254_740_991 && value.rounded() == value
    }
}
