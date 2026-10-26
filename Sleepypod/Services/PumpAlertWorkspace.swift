import Foundation
import Observation

@MainActor @Observable final class PumpAlertWorkspace {
    private(set) var alerts: [PumpAlert] = []
    private(set) var includesAcknowledged = false
    private(set) var receivedAt: Date?
    private(set) var loading = false
    private(set) var dismissing = false
    private(set) var error: String?
    private(set) var result: String?
    private(set) var failures: [Int: String] = [:]
    private let client: any PumpAlertClient
    init(client: any PumpAlertClient) { self.client = client }
    func canDismiss(now: Date = .now) -> Bool {
        guard !loading, !dismissing, error == nil, let receivedAt else { return false }
        return (0...90).contains(now.timeIntervalSince(receivedAt))
    }
    func load(includeAcknowledged: Bool? = nil, now: Date = .now) async {
        guard !loading, !dismissing else { return }
        loading = true
        defer { loading = false }
        let filter = includeAcknowledged ?? includesAcknowledged
        do {
            let value = try await client.list(includeAcknowledged: filter)
            guard !Task.isCancelled else { return }
            alerts = value; includesAcknowledged = filter; receivedAt = now; error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    // Freeze incident identities at review; never dismiss alerts that arrived after confirmation.
    func dismiss(_ reviewed: [PumpAlert], now: Date = .now) async {
        guard canDismiss(now: now), !reviewed.isEmpty,
              Set(reviewed.map(\.id)).count == reviewed.count,
              reviewed.allSatisfy({ alerts.contains($0) }) else {
            result = "The alert list changed or expired. Refresh and review it again."
            return
        }
        dismissing = true; failures = [:]; result = nil
        var confirmed = 0
        for alert in reviewed {
            if Task.isCancelled { break }
            do { try await client.dismiss(id: alert.id); confirmed += 1 }
            catch { failures[alert.id] = error.localizedDescription }
        }
        dismissing = false
        result = "\(confirmed) dismissal\(confirmed == 1 ? "" : "s") confirmed."
        // Read back even after a rejected or unknown result; no automatic mutation retry.
        await load()
        if !failures.isEmpty { result? += " Some results were not confirmed. Review the refreshed list below." }
    }
}
