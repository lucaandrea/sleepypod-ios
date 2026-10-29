import Foundation

enum NightStageCoverage {
    /// Clip to recorded windows, count overlaps once, and leave conflicting classifications unknown.
    static func epochs(_ epochs: [SleepAnalyzer.SleepEpoch], within intervals: [DateInterval]) -> [SleepAnalyzer.SleepEpoch] {
        var pieces: [SleepAnalyzer.SleepEpoch] = []
        for epoch in epochs where epoch.duration.isFinite && epoch.duration > 0 && epoch.start.timeIntervalSince1970.isFinite {
            for interval in intervals {
                let start = max(epoch.start, interval.start)
                let end = min(epoch.start.addingTimeInterval(epoch.duration), interval.end)
                guard end > start else { continue }
                pieces.append(copy(epoch, start: start, end: end))
            }
        }
        var starts: [Date: [Int]] = [:], ends: [Date: [Int]] = [:]
        for (index, piece) in pieces.enumerated() {
            starts[piece.start, default: []].append(index)
            ends[piece.start.addingTimeInterval(piece.duration), default: []].append(index)
        }
        let bounds = Set(starts.keys).union(ends.keys).sorted()
        var active: Set<Int> = [], result: [SleepAnalyzer.SleepEpoch] = []
        for (start, end) in zip(bounds, bounds.dropFirst()) {
            for index in ends[start] ?? [] { active.remove(index) }
            active.formUnion(starts[start] ?? [])
            guard let first = active.min(), active.allSatisfy({ pieces[$0].stage == pieces[first].stage }) else { continue }
            result.append(copy(pieces[first], start: start, end: end))
        }
        return result
    }

    private static func copy(_ epoch: SleepAnalyzer.SleepEpoch, start: Date, end: Date) -> SleepAnalyzer.SleepEpoch {
        .init(start: start, duration: end.timeIntervalSince(start), stage: epoch.stage,
              heartRate: epoch.heartRate, hrv: epoch.hrv, breathingRate: epoch.breathingRate)
    }
}
