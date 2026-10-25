import Foundation

struct HealthComparison: Sendable {
    struct Quantity: Sendable { var value: Double; var source: String; var at: Date }
    var from: Date
    var through: Date
    var asleepMinutes: Double?
    var sleepSources: [String]
    var heartRate: Quantity?
    var hrv: Quantity?
    var respiratoryRate: Quantity?

    static func mergedMinutes(_ intervals: [DateInterval], within range: DateInterval) -> Double? {
        let clipped = intervals.compactMap { interval -> DateInterval? in
            let start = max(interval.start, range.start), end = min(interval.end, range.end)
            return end > start ? DateInterval(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        var merged: [DateInterval] = []
        for interval in clipped {
            if let previous = merged.last, previous.end >= interval.start {
                merged[merged.count - 1] = DateInterval(start: previous.start, end: max(previous.end, interval.end))
            } else { merged.append(interval) }
        }
        return merged.isEmpty ? nil : merged.reduce(0) { $0 + $1.duration } / 60
    }
}
