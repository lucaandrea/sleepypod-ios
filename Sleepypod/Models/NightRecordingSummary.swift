import Foundation

/// Count recorded windows once. Gaps remain unknown instead of being filled as sleep.
struct NightRecordingSummary: Sendable {
    let intervals: [DateInterval]
    let recordCount: Int
    let ongoing: Bool
    var start: Date? { intervals.first?.start }
    var end: Date? { intervals.last?.end }
    var recordedSeconds: Int { Int(intervals.reduce(0) { $0 + $1.duration }) }
    var gapSeconds: Int {
        guard let start, let end else { return 0 }
        return max(0, Int(end.timeIntervalSince(start)) - recordedSeconds)
    }

    init(records: [SleepRecord]) {
        recordCount = Set(records.map(\.id)).count
        ongoing = records.contains(where: \.isOngoing)
        let windows = records.compactMap { record -> DateInterval? in
            let start = record.enteredBedDate
            // Open records only contribute their reported duration, never time since the last refresh.
            let end = record.completedAt ?? start.addingTimeInterval(Double(max(0, record.sleepPeriodSeconds)))
            guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
                  start.timeIntervalSince1970 > 0, end > start else { return nil }
            return DateInterval(start: start, end: end)
        }.sorted { $0.start < $1.start }
        var merged: [DateInterval] = []
        for window in windows {
            if let previous = merged.last, window.start <= previous.end {
                merged[merged.count - 1] = DateInterval(start: previous.start, end: max(previous.end, window.end))
            } else { merged.append(window) }
        }
        intervals = merged
    }
}
