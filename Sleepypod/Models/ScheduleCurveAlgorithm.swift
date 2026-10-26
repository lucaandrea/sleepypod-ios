import Foundation

/// Deterministic wall-clock preset generation shared by the curve editor and Night/Dawn setup.
/// Rounding matches Core's JavaScript algorithm, including negative half values and short nights.
enum ScheduleCurveAlgorithm {
    struct Point {
        let minutesFromBedtime: Int
        let tempOffset: Int
        let phase: SleepCurve.Phase
    }
    static func generate(bedtimeMinutes: Int, wakeMinutes: Int, intensity: CoolingIntensity = .balanced, minimum: Int = 68, maximum: Int = 86) -> [Point] {
        let duration = Double(wakeMinutes > bedtimeMinutes ? wakeMinutes - bedtimeMinutes : wakeMinutes - bedtimeMinutes + 1440)
        let ratios = intensity.ratios
        let coolRange = Double(80 - minimum), warmRange = Double(maximum - 80)
        let warmUp = rounded(warmRange * ratios.warmUp)
        let fallAsleep = -rounded(coolRange * ratios.fallAsleep)
        let deep = -coolRange, maintain = -rounded(coolRange * ratios.maintain), preWake = warmRange
        var points: [Point] = []
        func append(_ minutes: Double, _ offset: Double, _ phase: SleepCurve.Phase) {
            points.append(.init(minutesFromBedtime: Int(rounded(minutes)), tempOffset: Int(rounded(offset)), phase: phase))
        }
        append(-45, 0, .warmUp); append(-30, warmUp / 3, .warmUp)
        append(-15, warmUp * 2 / 3, .warmUp); append(0, warmUp, .warmUp)
        let cooling = min(90, duration * 0.15)
        append(cooling * 0.25, warmUp / 2, .coolDown); append(cooling * 0.5, fallAsleep / 2, .coolDown)
        append(cooling * 0.75, fallAsleep * 3 / 4, .coolDown); append(cooling, fallAsleep, .coolDown)
        let transition = min(60, duration * 0.1), deepStart = cooling + transition
        append(cooling + transition * 0.5, (fallAsleep + deep) / 2, .deepSleep)
        append(deepStart, deep, .deepSleep)
        let deepEnd = min(210, duration * 0.45)
        append((deepStart + deepEnd) / 2, deep, .deepSleep); append(deepEnd, deep, .deepSleep)
        let maintainStart = deepEnd + 45, maintainChange = maintain - deep
        append(deepEnd + 15, deep + maintainChange / 3, .maintain)
        append(deepEnd + 30, deep + maintainChange * 2 / 3, .maintain); append(maintainStart, maintain, .maintain)
        let preWakeStart = min(duration, max(maintainStart + 30, duration - 45))
        let wakeRamp = max(0, duration - preWakeStart)
        if preWakeStart > maintainStart + 30 { append((maintainStart + preWakeStart) / 2, maintain, .maintain) }
        append(preWakeStart, maintain, .maintain)
        append(preWakeStart + wakeRamp / 3, maintain + (preWake - maintain) / 3, .preWake)
        append(preWakeStart + wakeRamp * 2 / 3, maintain + (preWake - maintain) * 2 / 3, .preWake)
        append(duration, preWake, .preWake)
        append(duration + 10, preWake * 2 / 3, .wake); append(duration + 20, preWake / 3, .wake); append(duration + 30, 0, .wake)
        return points.sorted { $0.minutesFromBedtime < $1.minutesFromBedtime }
    }
    static func temperatures(bedtimeMinutes: Int, wakeMinutes: Int, intensity: CoolingIntensity = .balanced, minimum: Int = 68, maximum: Int = 86) -> [String: Double] {
        var result: [String: Double] = [:]
        for point in generate(bedtimeMinutes: bedtimeMinutes, wakeMinutes: wakeMinutes, intensity: intensity, minimum: minimum, maximum: maximum) {
            result[CurvePoint.clock(bedtimeMinutes + point.minutesFromBedtime)] = Double(80 + point.tempOffset)
        }
        return result
    }
    /// Remove only interior flat points while retaining midnight and long-gap ordering anchors.
    static func simplify(_ points: [CurvePoint]) -> [CurvePoint] {
        let ordered = CurvePoint.ordered(points)
        guard let first = ordered.first else { return [] }
        let minutes = ordered.map { $0.minutes + ($0.minutes < first.minutes ? 1440 : 0) }
        var kept: [CurvePoint] = [], lastKept = 0
        for (index, point) in ordered.enumerated() {
            let interior = index > 0 && index < ordered.count - 1
            let flat = interior && point.temperature == ordered[index - 1].temperature && point.temperature == ordered[index + 1].temperature
            let midnight = index > 0 && minutes[index] >= 1440 && minutes[index - 1] < 1440
            let longGap = index < ordered.count - 1 && minutes[index + 1] - minutes[lastKept] > 720
            if flat && !midnight && !longGap { continue }
            kept.append(point); lastKept = index
        }
        return kept
    }
    private static func rounded(_ value: Double) -> Double { floor(value + 0.5) }
}
