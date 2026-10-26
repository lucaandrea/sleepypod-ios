import Foundation
import FreeSleepKit

/// One bounded, read-only source for personal reports, local coaching and the summary Shortcut.
@MainActor final class NativeSleepEvidence {
    private let client: () throws -> any SleepypodProtocol
    private let owner: () -> [String]
    private let now: () -> Date
    init(client: @escaping () throws -> any SleepypodProtocol,
         owner: @escaping () -> [String] = { OwnerConnection.revision }, now: @escaping () -> Date = { .now }) {
        self.client = client; self.owner = owner; self.now = now
    }
    static func configured() -> NativeSleepEvidence {
        .init(client: {
            guard APIBackend.current == .sleepypodCore else { throw APIError.noBaseURL }
            let endpoint = try CoreRESTClient.configured().endpoint
            return SleepypodCoreClient(baseURL: endpoint)
        })
    }
    func load(side: Side, days: Int) async throws -> NativePodEvidence {
        guard [7, 30, 90].contains(days) else { throw Self.invalid }
        let scope = owner(), api = try client(), end = now()
        try check(scope)
        let settings = try await api.getSettings(); try check(scope)
        guard let zone = TimeZone(identifier: settings.timeZone) else { throw Self.invalid }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        guard let start = calendar.date(byAdding: .day, value: -days, to: end) else { throw Self.invalid }
        // Include completed records that began just before the window; duration is clipped below.
        let records = try await api.getSleepRecords(side: side, start: start.addingTimeInterval(-16 * 3600), end: end)
        try check(scope)
        let vitals: VitalsSummary?
        do { vitals = try await api.getVitalsSummary(side: side, start: start, end: end) }
        catch { try check(scope); vitals = nil }
        try check(scope)
        return try Self.calculate(records: records, vitals: vitals, side: side, days: days, zone: zone, range: start...end)
    }
    private func check(_ scope: [String]) throws {
        try Task.checkCancellation()
        guard owner() == scope else { throw NativeControlFailure.changedOwner }
    }
    static var invalid: APIError { .serverError(message: "This Pod summary is incomplete or invalid. Refresh the range before using it in a report.") }

    /// Union intervals before summing, then qualify wake-date coverage instead of inventing measured nights.
    static func calculate(records: [SleepRecord], vitals: VitalsSummary?, side: Side, days: Int,
                          zone: TimeZone, range: ClosedRange<Date>) throws -> NativePodEvidence {
        guard [7, 30, 90].contains(days), range.lowerBound < range.upperBound,
              records.count <= 20_000, Set(records.map(\.id)).count == records.count else { throw invalid }
        // Validate individual record identity and timestamps before making any absence claims.
        for record in records {
            guard record.side == side.rawValue, record.enteredBedDate.timeIntervalSince1970.isFinite,
                  record.enteredBedDate.timeIntervalSince1970 > 0, record.timesExitedBed >= 0 else { throw invalid }
            if let end = record.completedAt {
                guard end.timeIntervalSince1970.isFinite, end > record.enteredBedDate else { throw invalid }
            }
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        var byWakeDate: [Date: [TemperatureHistory.Interval]] = [:]
        var included = 0, excluded = 0
        for record in records {
            guard let end = record.completedAt, range.contains(end),
                  end.timeIntervalSince(record.enteredBedDate) >= 20 * 60,
                  end.timeIntervalSince(record.enteredBedDate) < 16 * 3600,
                  validIntervals(record) else { excluded += 1; continue }
            let intervals = TemperatureHistory.presence([record], side: side, in: range, now: range.upperBound)
            guard !intervals.isEmpty else { excluded += 1; continue }
            byWakeDate[calendar.startOfDay(for: end), default: []] += intervals
            included += 1
        }
        let merged = TemperatureHistory.clipped(byWakeDate.values.flatMap { $0 }, to: range, now: range.upperBound)
        let total = minutes(merged)
        let format = DateFormatter(); format.timeZone = zone; format.dateStyle = .medium; format.timeStyle = .short
        var facts: [NativeSleepFact] = [
            .init(id: "pod.range", text: "Pod \(side.rawValue) side, last \(days) calendar days: \(format.string(from: range.lowerBound)) to \(format.string(from: range.upperBound)) (\(zone.identifier))."),
            .init(id: "pod.coverage", text: "\(included) eligible completed presence records across \(byWakeDate.count) recorded wake dates. \(excluded) records outside the completed window, too short/long, ongoing or without usable intervals were excluded. Gaps are unknown; these dates are not measured sleep nights.")
        ]
        let summary: String
        if !byWakeDate.isEmpty {
            let average = Int((total / Double(byWakeDate.count)).rounded())
            facts.append(.init(id: "pod.presence", text: "\(Int(total.rounded())) minutes of reported bed presence, preserving exits and removing overlap. Mean across recorded wake dates: \(average) minutes. Presence does not establish sleep duration, stages or quality."))
            if let latest = byWakeDate.keys.max(), let intervals = byWakeDate[latest] {
                format.timeStyle = .none
                let duration = minutes(TemperatureHistory.clipped(intervals, to: range, now: range.upperBound))
                facts.append(.init(id: "pod.latest", text: "Latest recorded wake date: \(format.string(from: latest)); \(Int(duration.rounded())) reported presence minutes in this range."))
            }
            summary = "\(side.displayName) side, last \(days) days (\(zone.identifier)): \(average) average reported presence minutes across \(byWakeDate.count) recorded wake dates. Presence is not measured sleep; missing dates are unknown."
        } else {
            summary = "\(side.displayName) side, last \(days) days (\(zone.identifier)): no eligible completed presence records. This does not establish zero sleep."
        }
        let vitalFacts = NativeVitalEvidence.facts(vitals)
        facts += vitalFacts
        return .init(side: side.rawValue, days: days, timeZone: zone.identifier, start: range.lowerBound, end: range.upperBound,
                     facts: facts, summary: summary, hasObservations: !merged.isEmpty || vitalFacts.contains { ["pod.heart", "pod.breathing", "pod.hrv"].contains($0.id) })
    }
    private static func minutes(_ intervals: [TemperatureHistory.Interval]) -> Double {
        intervals.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / 60
    }
    private static func validIntervals(_ record: SleepRecord) -> Bool {
        guard let raw = record.presentIntervals, !raw.isEmpty, raw != "null" else { return record.timesExitedBed == 0 }
        guard raw.utf8.count <= 1_048_576, let data = raw.data(using: .utf8),
              let pairs = try? JSONDecoder().decode([[Double?]].self, from: data), pairs.count <= 10_000 else { return false }
        if pairs.isEmpty { return record.timesExitedBed == 0 }
        return pairs.allSatisfy { pair in
            guard pair.count == 2, let lower = pair[0], lower.isFinite, lower > 0 else { return false }
            guard let upper = pair[1] else { return true }
            return upper.isFinite && upper > lower
        }
    }
}
