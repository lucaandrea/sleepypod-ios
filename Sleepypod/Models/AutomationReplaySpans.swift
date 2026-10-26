import Foundation

enum AutomationReplaySpans {
    /// Merge adjacent sample indices, discarding duplicates and out-of-range values.
    static func grouped(_ indices: [Int], count: Int) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        for index in Set(indices).filter({ (0..<count).contains($0) }).sorted() {
            if let last = result.last, last.upperBound + 1 == index { result[result.count - 1] = last.lowerBound...index }
            else { result.append(index...index) }
        }
        return result
    }
    static func timeWindows(_ result: AutomationBacktest.Result) -> [ClosedRange<Int>] {
        guard let window = result.timeWindow, window.startMin.isFinite, window.endMin.isFinite, window.startMin != window.endMin else { return [] }
        let selected = result.clockMin.enumerated().compactMap { index, value -> Int? in
            guard value.isFinite else { return nil }
            let minute = value.truncatingRemainder(dividingBy: 1440)
            let inside = window.startMin < window.endMin ? (window.startMin..<window.endMin).contains(minute) : minute >= window.startMin || minute < window.endMin
            return inside ? index : nil
        }
        return grouped(selected, count: result.clockMin.count)
    }
}
