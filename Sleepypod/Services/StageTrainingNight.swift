import Foundation

/// One local-noon night is one validation unit, even when the Pod saved several fragments.
struct StageTrainingNight: Sendable {
    let records: [SleepRecord]
    let date: Date
    var id: Int { records.map(\.id).min() ?? 0 }
    var start: Date { records.map(\.enteredBedDate).min() ?? date }
    var end: Date { records.map(\.leftBedDate).max() ?? date }
    var window: DateInterval { DateInterval(start: start, end: max(start, end)) }

    static func grouped(_ records: [SleepRecord], calendar: Calendar) -> [Self] {
        let unique = Dictionary(grouping: records, by: \.id).compactMap { $0.value.first }
        let groups = Dictionary(grouping: unique) { SleepCalendar.nightDate(for: $0.enteredBedDate, calendar: calendar) }
        var nights: [Self] = []
        for (date, records) in groups.sorted(by: { $0.key < $1.key }) {
            let night = Self(records: records.sorted { $0.enteredBedDate < $1.enteredBedDate }, date: date)
            // A record crossing noon cannot appear in a different validation fold from an overlapping record.
            if let previous = nights.last, night.start < previous.end {
                nights[nights.count - 1] = Self(records: previous.records + night.records, date: previous.date)
            } else { nights.append(night) }
        }
        return nights
    }

    var presence: [DateInterval]? {
        var intervals: [DateInterval] = []
        for record in records {
            guard let text = record.presentIntervals, let data = text.data(using: .utf8),
                  let pairs = try? JSONDecoder().decode([[Double]].self, from: data), !pairs.isEmpty else { return nil }
            for pair in pairs {
                guard pair.count == 2, pair.allSatisfy(\.isFinite) else { return nil }
                let start = Date(timeIntervalSince1970: pair[0] > 1e11 ? pair[0] / 1000 : pair[0])
                let end = Date(timeIntervalSince1970: pair[1] > 1e11 ? pair[1] / 1000 : pair[1])
                guard start >= record.enteredBedDate, end <= record.leftBedDate, end > start else { return nil }
                intervals.append(DateInterval(start: start, end: end))
            }
        }
        return intervals
    }

    func issue(now: Date) -> String? {
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, start > Date(timeIntervalSince1970: 0), end > start else {
            return "Invalid recording timestamps"
        }
        guard !records.contains(where: \.isOngoing), end <= now else { return "Recording still in progress" }
        guard Set(records.map(\.side)).count == 1 else { return "Mixed bed sides" }
        guard window.duration >= StageTrainingCoverage.minimumNightSeconds else { return "Short or partial recording" }
        guard window.duration <= StageTrainingCoverage.maximumNightSeconds else { return "Recording spans more than one sleep opportunity" }
        guard let presence else { return "Recorded presence intervals are missing or inconsistent" }
        return StageTrainingCoverage.issue(presence, within: window).map { "Pod presence: \($0)" }
    }
}
