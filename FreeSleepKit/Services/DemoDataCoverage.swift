import Foundation

// The labelled demo mirrors the server's calendar rules; live clients display the server report.
enum DemoDataCoverage {
    static func build(_ nights: [SleepAnalytics.Night], timeZone: String) -> DataCoverage {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: timeZone) ?? .gmt
        let records = Dictionary(nights.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        let latest = records.keys.sorted().last.flatMap { JournalDate.date($0, timeZone: timeZone) }
        func window(offset: Int) -> DataCoverage.Window? {
            guard let latest else { return nil }
            let days: [DataCoverage.Day] = (0..<7).compactMap { index in
                guard let date = calendar.date(byAdding: .day, value: -(offset + 6 - index), to: latest) else { return nil }
                let key = JournalDate.key(date, timeZone: timeZone)
                let night = records[key]
                return .init(date: key, status: night == nil ? "not_returned" : night?.occupiedMinutes == nil ? "unknown" : "known")
            }
            guard let first = days.first, let last = days.last else { return nil }
            let returned = days.compactMap { records[$0.date] }
            return .init(from: first.date, through: last.date, days: days, recordedNights: returned.count,
                presenceNights: returned.compactMap(\.occupiedMinutes).count, heartRateNights: returned.compactMap(\.heartRate).count,
                hrvNights: returned.compactMap(\.hrv).count, respiratoryRateNights: returned.compactMap(\.respiratoryRate).count)
        }
        let recent = window(offset: 0); let previous = window(offset: 7)
        let available = (recent?.presenceNights ?? 0) >= 3 && (previous?.presenceNights ?? 0) >= 3
        return .init(version: 1, minimumNights: 3, recent: recent, previous: previous, comparisonAvailable: available,
            comparisonReason: available
                ? "Both periods have at least 3 nights with known presence. This is a descriptive comparison, not proof of a change in sleep quality."
                : "A weekly change needs at least 3 nights with known presence in each period. This is an app display rule, not a medical confidence threshold.",
            excludedEpisodes: 0,
            scopeNote: "Based on records returned for your selected range. A date without a record does not prove sensor failure or no sleep. Choose a longer range to include earlier dates.")
    }
}
