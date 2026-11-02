import Foundation

/// Conservative engineering gates for complete recordings; they do not classify sleep or diagnose its quality.
enum StageTrainingCoverage {
    static let minimumNightSeconds: TimeInterval = 6 * 3600
    static let maximumNightSeconds: TimeInterval = 12 * 3600
    static let maximumGapSeconds: TimeInterval = 30 * 60
    static let minimumFraction = 0.9

    static func merged(_ intervals: [DateInterval], within window: DateInterval) -> [DateInterval] {
        let clipped = intervals.compactMap { interval -> DateInterval? in
            let start = max(interval.start, window.start), end = min(interval.end, window.end)
            guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, end > start else { return nil }
            return DateInterval(start: start, end: end)
        }.sorted { $0.start < $1.start }
        var result: [DateInterval] = []
        for interval in clipped {
            if let previous = result.last, interval.start <= previous.end {
                result[result.count - 1] = DateInterval(start: previous.start, end: max(previous.end, interval.end))
            } else { result.append(interval) }
        }
        return result
    }

    /// Count the union once and inspect both edges. A dense fragment cannot pass as a complete night.
    static func issue(_ intervals: [DateInterval], within window: DateInterval) -> String? {
        guard window.duration.isFinite, window.duration > 0 else { return "Invalid night window" }
        let merged = merged(intervals, within: window)
        guard let first = merged.first, let last = merged.last else { return "No coverage" }
        let duration = merged.reduce(0) { $0 + $1.duration }
        guard duration / window.duration >= minimumFraction else { return "Less than 90% of the night is covered" }
        guard first.start.timeIntervalSince(window.start) <= maximumGapSeconds,
              window.end.timeIntervalSince(last.end) <= maximumGapSeconds,
              zip(merged, merged.dropFirst()).allSatisfy({ pair in pair.1.start.timeIntervalSince(pair.0.end) <= maximumGapSeconds }) else {
            return "A gap exceeds 30 minutes"
        }
        return nil
    }

    static func hasConflictingStages(_ stages: [WatchComparison.StageSample]) -> Bool {
        let sorted = stages.sorted { $0.start < $1.start }
        for (index, stage) in sorted.enumerated() {
            for later in sorted.dropFirst(index + 1) {
                if later.start >= stage.end { break }
                if later.stage != stage.stage && later.end > stage.start { return true }
            }
        }
        return false
    }
}
