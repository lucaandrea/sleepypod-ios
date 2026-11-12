#if DEBUG
import Foundation

/// Clearly labelled simulator examples never open a session or send a controller command.
@MainActor final class WatchBedExample {
    private var target = 70
    private let state: String
    init(state: String) { self.state = state }
    func send(_ data: Data) async throws -> Data {
        let request = try JSONDecoder().decode(BedRemoteRequest.self, from: data)
        if state == "offline" { throw URLError(.notConnectedToInternet) }
        let reply: BedRemoteReply
        if request.action == .refresh {
            let now = Date(), stale = state == "stale", split = state == "split"
            let zones = [BedRemoteSnapshot.Zone(id: "left", measuredF: stale ? nil : 70.2, requestedF: target, powered: true)]
                + (split ? [.init(id: "right", measuredF: 74.1, requestedF: 74, powered: true)] : [])
            reply = .init(requestID: request.id, outcome: .snapshot,
                snapshot: .init(lease: UUID(), receivedAt: now, expiresAt: now.addingTimeInterval(30),
                    observationAt: now.addingTimeInterval(stale ? -60 : -1), person: "Example sleeper",
                    assignment: split ? "Both sides" : "Left side", zones: zones,
                    nextAlarm: "Tomorrow: warming 6:30 AM. Vibration 7:00 AM for 20 seconds.",
                    canAdjust: !stale, canStop: true, explanation: "Manual temperature hold · 30 minutes"),
                message: "Preview · no bed commands")
        } else {
            if let value = request.temperatureF { target = value }
            reply = .init(requestID: request.id, outcome: .acknowledged, snapshot: nil,
                message: "Preview only. Your bed has not changed.")
        }
        return try JSONEncoder().encode(reply)
    }
}
#endif
