import Foundation

/// A frozen drag domain keeps the axes still while a set point moves.
struct CurveChartProjection: Equatable, Sendable {
    let start: Double
    let end: Double
    let low: Double
    let high: Double
    let overnight: Bool

    init(points: [CurvePoint]) {
        let ordered = CurvePoint.ordered(points)
        let wraps = ordered.first.map { first in ordered.contains { $0.minutes < first.minutes } } ?? false
        overnight = wraps
        let minutes = ordered.map { Double($0.minutes + (wraps && $0.minutes < 720 ? 1440 : 0)) }
        let first = minutes.min() ?? 1320, last = minutes.max() ?? 1740
        let span = last - first + 60, step = span <= 720 ? 120.0 : span <= 1080 ? 180.0 : 240.0
        start = floor((first - 30) / step) * step
        end = max(ceil((last + 30) / step) * step, start + 2 * step)
        var lower = floor(((points.map(\.temperature).min() ?? 80) - 4) / 2) * 2
        var upper = ceil(((points.map(\.temperature).max() ?? 80) + 4) / 2) * 2
        if upper - lower < 8 { lower -= floor((8 - (upper - lower)) / 4) * 2; upper = lower + 8 }
        low = lower; high = upper
    }
    func minute(_ point: CurvePoint) -> Double { Double(point.minutes + (overnight && point.minutes < 720 ? 1440 : 0)) }
    func horizontal(_ point: CurvePoint) -> Double { (minute(point) - start) / (end - start) }
    func vertical(_ point: CurvePoint) -> Double { (high - point.temperature) / (high - low) }
    func moved(_ point: CurvePoint, horizontal: Double, vertical: Double) -> CurvePoint {
        guard horizontal.isFinite, vertical.isFinite else { return point }
        var result = point
        let minute = start + min(1, max(0, horizontal)) * (end - start)
        result.time = CurvePoint.clock(Int(floor(minute / 15 + 0.5)) * 15)
        result.temperature = min(110, max(55, floor(high - min(1, max(0, vertical)) * (high - low) + 0.5)))
        return result
    }
}
