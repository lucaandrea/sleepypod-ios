import Foundation

/// Care is a set of independently expiring observations, not an overall health score.
struct BedCare: Codable, Sendable, Equatable {
    struct Check: Codable, Sendable, Identifiable, Equatable {
        struct Evidence: Codable, Sendable, Equatable { let title: String; let detail: String }
        let id: String
        let title: String
        let state: String
        let detail: String
        let nextStep: String
        let observedAt: Double?
        let expiresAt: Double?
        let destination: String
        let evidence: [Evidence]

        func current(at date: Date) -> Bool {
            if state == "unknown", observedAt == nil { return true }
            let now = date.timeIntervalSince1970 * 1000
            guard let observedAt, let expiresAt else { return false }
            return observedAt <= now && observedAt >= now - 30_000 && expiresAt > now && expiresAt <= observedAt + 30_000
        }
        var statusLabel: String {
            switch state {
            case "checked": "Checked"
            case "attention": "Needs attention"
            case "busy": "In progress"
            default: "Not verified"
            }
        }
        func advice(current: Bool) -> String {
            current ? nextStep : "Reconnect and check again before acting on this observation."
        }
        var destinationLabel: String {
            switch destination {
            case "thermal": "View temperature delivery"
            case "dashboard": "Review pump alerts"
            case "health": "Open recording diagnostics"
            case "storage": "Review storage"
            default: "Open backups"
            }
        }
    }
    let apiVersion: Int
    let generatedAt: Double
    let checks: [Check]
    let lastExportAt: Double?
    static let requiredChecks: Set<String> = ["water", "circulation", "recording", "storage", "backup"]
    var checkedDate: Date { Date(timeIntervalSince1970: generatedAt / 1000) }
    var exportDate: Date? { lastExportAt.map { Date(timeIntervalSince1970: $0 / 1000) } }

    func validate() throws {
        guard apiVersion == 1, Self.validTime(generatedAt), checks.count == 5, Set(checks.map(\.id)) == Self.requiredChecks,
              lastExportAt.map({ Self.validTime($0) && $0 <= generatedAt }) ?? true,
              checks.allSatisfy({ check in
                  ["checked", "attention", "unknown", "busy"].contains(check.state)
                    && ["thermal", "dashboard", "health", "storage", "databases"].contains(check.destination)
                    && (check.observedAt.map { Self.validTime($0) && $0 <= generatedAt } ?? (check.state == "unknown"))
                    && (check.expiresAt.map { Self.validTime($0) && check.observedAt != nil && $0 <= (check.observedAt ?? 0) + 30_000 } ?? (check.observedAt == nil))
                    && check.title.count <= 160 && check.detail.count <= 4_000 && check.nextStep.count <= 4_000 && check.evidence.count <= 16
              }) else { throw APIError.serverError(message: "The controller returned an unsupported bed-care report. Update the controller and try again.") }
    }
    func current(at date: Date) -> Bool {
        let now = date.timeIntervalSince1970 * 1000
        return (try? validate()) != nil && now.isFinite && generatedAt <= now && generatedAt >= now - 30_000
    }
    private static func validTime(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= 9_007_199_254_740_991 && value.rounded() == value
    }
}

struct BedCareExample: Decodable, Sendable {
    let synthetic: Bool
    let sourceCommit: String
    let now: Double
    let cases: [String: BedCare]
    static func load() throws -> Self {
        guard let file = Bundle.main.url(forResource: "bed-care-example", withExtension: "json") else { throw APIError.invalidResponse(statusCode: 0) }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }
}
