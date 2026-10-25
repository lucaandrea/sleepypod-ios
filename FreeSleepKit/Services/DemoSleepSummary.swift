import Foundation

enum DemoSleepSummary {
    static func round(_ value: Double) -> Double { floor(value * 10 + 0.5) / 10 }
    static func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : round(values.reduce(0, +) / Double(values.count)) }
    static func analytics(_ episodes: [SleepAnalytics.Night], timeZone: String) -> SleepAnalytics {
        var daily: [String: SleepAnalytics.Night] = [:]
        for episode in episodes where (daily[episode.date]?.windowMinutes ?? -1) < (episode.windowMinutes ?? 0) { daily[episode.date] = episode }
        let nights = daily.values.sorted { $0.date < $1.date }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: timeZone) ?? .gmt
        let latest = nights.last.flatMap { JournalDate.date($0.date, timeZone: timeZone) } ?? Date(timeIntervalSince1970: 0)
        let recentStart = JournalDate.key(calendar.date(byAdding: .day, value: -6, to: latest)!, timeZone: timeZone)
        let previousStart = JournalDate.key(calendar.date(byAdding: .day, value: -13, to: latest)!, timeZone: timeZone)
        let recent = nights.filter { $0.date >= recentStart }
        let previous = nights.filter { $0.date >= previousStart && $0.date < recentStart }
        let coverage = DemoDataCoverage.build(nights, timeZone: timeZone)
        let average = mean(recent.compactMap(\.occupiedMinutes)); let previousAverage = mean(previous.compactMap(\.occupiedMinutes))
        let bedtimes = recent.compactMap { night -> Double? in
            guard let date = EpisodeDetail.date(night.startedAt) else { return nil }
            let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
            return Double(minute < 720 ? minute + 1440 : minute)
        }
        let variation: Double? = bedtimes.count >= 3 ? mean(bedtimes).map { average in
            round(sqrt(bedtimes.reduce(0) { $0 + pow($1 - average, 2) } / Double(bedtimes.count)))
        } : nil
        return .init(quality: .init(coverage: coverage), timeZone: timeZone, nights: nights, episodes: episodes, summary: .init(recordedNights: nights.count,
            averageOccupiedMinutes: average, averageHeartRate: mean(recent.compactMap(\.heartRate)), averageHrv: mean(recent.compactMap(\.hrv)),
            averageRespiratoryRate: mean(recent.compactMap(\.respiratoryRate)), bedtimeVariationMinutes: variation,
            weeklyChangeMinutes: !coverage.comparisonAvailable ? nil : average.flatMap { current in previousAverage.map { round(current - $0) } }))
    }
    static func coaching(_ analytics: SleepAnalytics, provider: String) -> Coaching {
        let summary = analytics.summary
        var observations: [String] = []; var suggestions: [String] = []
        if let presence = summary.averageOccupiedMinutes {
            observations.append("For the recorded period ending \(analytics.nights.last?.date ?? "unknown"), average bed presence is \(Int(floor(presence + 0.5))) minutes per recorded night.")
            if 480 - presence > 30 { suggestions.append("Protect a little more time in bed if your 480-minute personal goal still fits your routine.") }
        }
        if let variation = summary.bedtimeVariationMinutes {
            observations.append("Bed-entry timing varies by about \(Int(floor(variation + 0.5))) minutes across recent recorded nights.")
            if variation > 45 { suggestions.append("Try a more consistent wind-down time, then compare another week of observations.") }
        }
        if let change = summary.weeklyChangeMinutes {
            let value = change.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).precision(.fractionLength(0...1)))
            observations.append("Average bed presence changed by \(change > 0 ? "+" : "")\(value) minutes.")
        }
        if observations.isEmpty { observations.append("No usable bed-presence records are available for this period.") }
        if suggestions.isEmpty { suggestions.append("Keep your routine comfortable and collect more nights before changing several things at once.") }
        return .init(headline: summary.recordedNights > 0 ? "A little context for your nights" : "Your story starts with a night",
            observations: observations, suggestions: suggestions,
            limitations: ["Presence is not measured sleep; sleep stages and diagnoses cannot be inferred here.", "HRV and breathing estimates have not been validated."] + (analytics.quality?.coverage.map { [$0.comparisonReason] } ?? []),
            provider: provider, model: "Demo insights", grounding: DemoCoachFacts.grounding(analytics, observations: observations))
    }
}
