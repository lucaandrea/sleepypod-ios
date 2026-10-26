import Foundation

/// Generates a science-backed temperature curve from bedtime and wake time.
///
/// References:
/// - Heller 2012: warming before bed dilates blood vessels, accelerates core heat loss
/// - Kräuchi 2007: core body temp drop of 1-2°F triggers sleep onset
/// - Czeisler 1999: rising body temp 30min before wake triggers natural waking
/// - Walker 2017: sleep quality correlates with thermal environment
struct SleepCurve {

    /// A point on the temperature curve
    struct Point: Identifiable, Sendable {
        let id = UUID()
        let time: Date
        let tempOffset: Int  // relative to base (80°F), e.g. -6 = 74°F
        let phase: Phase
    }

    enum Phase: String, Sendable {
        case warmUp = "Wind Down"
        case coolDown = "Fall Asleep"
        case deepSleep = "Deep Sleep"
        case maintain = "Maintain"
        case preWake = "Pre-Wake"
        case wake = "Wake"
    }

    /// Generate a temperature curve from bedtime and wake time.
    /// Returns sorted points with ~15 minute intervals.
    static func generate(
        bedtime: Date,
        wakeTime: Date,
        coolingIntensity: CoolingIntensity = .balanced,
        minTempF: Int = 68,
        maxTempF: Int = 86,
        calendar: Calendar = .current
    ) -> [Point] {
        let bedtimeMinutes = calendar.component(.hour, from: bedtime) * 60 + calendar.component(.minute, from: bedtime)
        let wakeMinutes = calendar.component(.hour, from: wakeTime) * 60 + calendar.component(.minute, from: wakeTime)
        return ScheduleCurveAlgorithm.generate(bedtimeMinutes: bedtimeMinutes, wakeMinutes: wakeMinutes,
            intensity: coolingIntensity, minimum: minTempF, maximum: maxTempF).map { point in
                Point(time: bedtime.addingTimeInterval(Double(point.minutesFromBedtime) * 60), tempOffset: point.tempOffset, phase: point.phase)
            }
    }

    /// Convert curve points to schedule set points (HH:mm → tempF pairs).
    /// If multiple points share the same HH:mm timestamp, the last one wins.
    static func toScheduleTemperatures(_ points: [Point], baseTempF: Int = 80) -> [String: Int] {
        var result: [String: Int] = [:]
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"

        // Sample at key transitions only
        for point in points {
            let key = formatter.string(from: point.time)
            result[key] = baseTempF + point.tempOffset
        }
        return result
    }
}

// MARK: - Cooling Intensity

enum CoolingIntensity: String, CaseIterable, Identifiable, Sendable {
    case cool = "Cool"
    case balanced = "Balanced"
    case warm = "Warm"

    var id: String { rawValue }

    var offsets: (warmUp: Int, fallAsleep: Int, deepSleep: Int, maintain: Int, preWake: Int) {
        switch self {
        case .cool:     (+1, -6, -8, -6, +2)
        case .balanced: (+2, -4, -6, -4, +4)
        case .warm:     (+3, -2, -4, -2, +6)
        }
    }

    /// Ratios of the available temp range each phase uses (0.0 to 1.0)
    /// deepSleep and preWake always use 100% — they define the min/max
    var ratios: (warmUp: Double, fallAsleep: Double, maintain: Double) {
        switch self {
        case .cool:     (0.2, 0.7, 0.6)    // aggressive cooling
        case .balanced: (0.3, 0.6, 0.5)    // moderate
        case .warm:     (0.5, 0.4, 0.3)    // gentle cooling
        }
    }

    var description: String {
        switch self {
        case .cool: "Extra cooling for hot sleepers"
        case .balanced: "Science-backed defaults for most people"
        case .warm: "Gentler cooling, warmer wake-up"
        }
    }
}
