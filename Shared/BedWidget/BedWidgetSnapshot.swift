import Foundation

/// A short-lived display copy. It contains no credentials, health records or actuator lease.
struct BedWidgetSnapshot: Codable, Equatable, Sendable {
    struct Zone: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let requestedF: Int?
        let powered: Bool?
    }
    static let lifetime: TimeInterval = 15 * 60
    let version: Int
    let assignment: String
    let zones: [Zone]
    let nextWake: String
    let checkedAt: Date
    var wake: BedRemoteWake?

    var targetExpiresAt: Date { checkedAt.addingTimeInterval(Self.lifetime) }
    var expiresAt: Date {
        guard let wake, wake.valid(checkedAt: checkedAt) else { return targetExpiresAt }
        return max(targetExpiresAt, min(wake.at, checkedAt.addingTimeInterval(18 * 3_600)))
    }
    func hasRecentTargets(at now: Date) -> Bool { checkedAt <= now && now < targetExpiresAt }
    func savedWake(at now: Date) -> BedRemoteWake? {
        guard let wake, wake.valid(checkedAt: checkedAt), checkedAt <= now,
              now < wake.at, now < checkedAt.addingTimeInterval(18 * 3_600) else { return nil }
        return wake
    }
    func isUsable(at now: Date) -> Bool {
        version == 1 && checkedAt.timeIntervalSince1970.isFinite && now.timeIntervalSince1970.isFinite
            && checkedAt <= now && now < expiresAt
            && !assignment.isEmpty && assignment.count <= 100
            && !nextWake.isEmpty && nextWake.count <= 500
            && (wake.map { $0.valid(checkedAt: checkedAt) } ?? true)
            && !zones.isEmpty && zones.count <= 2 && Set(zones.map(\.id)).count == zones.count
            && zones.allSatisfy { ["left", "right"].contains($0.id)
                && ($0.requestedF.map { (55...110).contains($0) } ?? true) }
    }
    var targetLabel: String {
        if zones.allSatisfy({ $0.powered == false }) { return "Off" }
        let labels = zones.sorted { $0.id < $1.id }.map { zone in
            if zone.powered == false { return "Off" }
            return zone.requestedF.map { "\($0)°F" } ?? "—"
        }
        return Set(labels).count == 1 ? labels[0] : labels.joined(separator: " / ")
    }
}

enum BedWidgetRoute {
    static let url = URL(string: "sleepypod-widget://tonight")!
    /// A link opens the current account's controls, never an account or command from a URL.
    static func accepts(_ url: URL) -> Bool { url.absoluteString == self.url.absoluteString }
}
