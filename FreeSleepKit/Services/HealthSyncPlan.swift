import Foundation

enum HealthSyncPlan {
    enum Trigger: Sendable { case manual, foreground, background }

    // Automatic runs overlap two days to pick up corrected records; manual sync always reconciles thirty days.
    static func window(settings: HealthSyncSettings, trigger: Trigger, now: Date) -> DateInterval? {
        if trigger != .manual {
            guard settings.automatic else { return nil }
            if let attempted = settings.lastAttempt, now.timeIntervalSince(attempted) < 15 * 60 { return nil }
            if trigger == .background && settings.lastSuccess == nil { return nil }
        }
        let earliest = now.addingTimeInterval(-30 * 86400)
        let start = trigger == .manual ? earliest : max(earliest, (settings.lastSuccess ?? earliest).addingTimeInterval(-2 * 86400))
        guard start < now else { return nil }
        return DateInterval(start: start, end: now)
    }
}
