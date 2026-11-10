import Foundation

/// Describes returned sleep intervals, never inferred recording completeness or Health permission state.
struct WatchRecordingSummary: Equatable {
    enum State { case notRead, refreshNeeded, noRecordsReturned, waitingForRecentRecords, recordsAvailable }
    struct Day: Identifiable, Equatable {
        var id: Date
        var wakeDate: Date
        var night: HealthHistory.Night?
    }
    var state: State
    var importedAt: Date?
    var latest: HealthHistory.Night?
    var days: [Day]

    init(history: HealthHistory, now: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: history.timeZone) ?? .current
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let lastBucket = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: yesterday) ?? yesterday
        let nights = (history.watchNights ?? []).filter {
            $0.end <= now && $0.start < $0.end && $0.asleepMinutes.isFinite && $0.asleepMinutes > 0
        }
        days = (-6...0).compactMap { offset in
            guard let bucket = calendar.date(byAdding: .day, value: offset, to: lastBucket),
                  let wakeDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: bucket)) else { return nil }
            return Day(id: bucket, wakeDate: wakeDate, night: nights.first { $0.id == bucket.ISO8601Format() })
        }
        importedAt = history.importedAt == .distantPast ? nil : history.importedAt
        latest = nights.max { $0.end < $1.end }
        if importedAt == nil { state = .notRead }
        else if history.watchNights == nil || history.importedAt > now.addingTimeInterval(300) { state = .refreshNeeded }
        else if nights.isEmpty { state = .noRecordsReturned }
        else if days.last?.night == nil { state = .waitingForRecentRecords }
        else { state = .recordsAvailable }
    }

    var title: String {
        switch state {
        case .notRead: "Connect your Watch sleep history"
        case .refreshNeeded: "Refresh Watch source details"
        case .noRecordsReturned: "No Watch sleep returned yet"
        case .waitingForRecentRecords: "Recent Watch sleep is missing"
        case .recordsAvailable: "Watch sleep records are available"
        }
    }
    var explanation: String {
        switch state {
        case .notRead: "Read accessible Apple Health history on this device to see when your Watch sleep last arrived."
        case .refreshNeeded: "This import does not have current Watch source details. Refresh before assessing coverage."
        case .noRecordsReturned: "Health returned no identifiable Watch sleep. It may still be syncing, unavailable to this app, or not recorded."
        case .waitingForRecentRecords: "Earlier Watch records are saved, but none were returned for the latest overnight window. Missing records do not mean you slept zero hours."
        case .recordsAvailable: "These are the intervals Health labelled asleep. Their presence does not establish that the whole night was recorded."
        }
    }
    static func isWatch(productType: String?, model: String?, hardwareVersion: String?) -> Bool {
        productType?.lowercased().hasPrefix("watch") == true || model?.lowercased() == "watch"
            || hardwareVersion?.lowercased().hasPrefix("watch") == true
    }
}

enum HealthHistoryRefreshPolicy {
    /// Morning retries accommodate delayed Watch sync. Background execution remains an iOS decision.
    static func shouldRefresh(now: Date, importedAt: Date, lastAttempt: Date?, enabled: Bool, requested: Bool,
                              timeZone: TimeZone = .current) -> Bool {
        guard enabled, requested else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let morning = (4..<14).contains(calendar.component(.hour, from: now))
        let interval: TimeInterval = morning ? 30 * 60 : 6 * 3600
        if let lastAttempt {
            let elapsed = now.timeIntervalSince(lastAttempt)
            if elapsed >= 0 && elapsed < 15 * 60 { return false }
        }
        return importedAt > now.addingTimeInterval(300) || now.timeIntervalSince(importedAt) >= interval
    }
}
