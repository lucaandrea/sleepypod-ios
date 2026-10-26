import Foundation

struct SensorOccupancy: Decodable, Sendable {
    struct BedSide: Decodable, Sendable {
        struct Movement: Decodable, Sendable { let active: Bool; let peakScore: Double }
        struct Level: Decodable, Sendable {
            let active: Bool
            let deviation: Double?
            let threshold: Double?
            let ageMs: Double?
            let zoneDeviations: [Double]?
            let zones: Int?
        }
        struct Vitals: Decodable, Sendable { let heartRate: Double?; let breathingRate: Double?; let humanRange: Bool? }
        let occupied: Bool
        let available: Bool
        let classification: String
        let movement: Movement
        let level: Level
        let vitals: Vitals
        var label: String {
            if occupied { return classification == "light" ? "Light load" : "In bed" }
            return available ? "Empty" : "Unknown"
        }
        var detail: String {
            let motion = movement.active ? "Movement detected" : "No recent movement"
            return available ? motion : "Presence sensing unavailable · \(motion.lowercased())"
        }
    }
    let left: BedSide
    let right: BedSide
    func side(_ side: Side) -> BedSide { side == .left ? left : right }
}

struct SensorBedReading: Decodable, Sendable {
    let timestamp: String
    let ambientTemp: Double?
    let mcuTemp: Double?
    let humidity: Double?
    let leftOuterTemp: Double?
    let leftCenterTemp: Double?
    let leftInnerTemp: Double?
    let rightOuterTemp: Double?
    let rightCenterTemp: Double?
    let rightInnerTemp: Double?
    var date: Date? { SensorObservation.date(timestamp) }
    func side(_ side: Side) -> BedTempSide {
        let values = side == .left ? [leftOuterTemp, leftCenterTemp, leftInnerTemp] : [rightOuterTemp, rightCenterTemp, rightInnerTemp]
        return .init(amb: ambientTemp.map(Float.init), hu: humidity.map(Float.init), temps: values.map { SensorObservation.finite($0).map(Float.init) ?? -327.68 })
    }
}

struct SensorFreezerReading: Decodable, Sendable {
    let timestamp: String
    let ambientTemp: Double?
    let heatsinkTemp: Double?
    let leftWaterTemp: Double?
    let rightWaterTemp: Double?
    var date: Date? { SensorObservation.date(timestamp) }
}

struct SensorEnvironmentSummary: Decodable, Sendable {
    struct Bed: Decodable, Sendable {
        let avgAmbientTemp: Double?
        let minAmbientTemp: Double?
        let maxAmbientTemp: Double?
        let avgHumidity: Double?
        let avgLeftCenterTemp: Double?
        let avgRightCenterTemp: Double?
        let recordCount: Int
    }
    let bedTemp: Bed?
}

struct SensorFlowReading: Decodable, Sendable {
    let timestamp: String
    let leftFlowrateCd: Double?
    let rightFlowrateCd: Double?
    let leftPumpRpm: Double?
    let rightPumpRpm: Double?
    var date: Date? { SensorObservation.date(timestamp) }
    func value(side: Side, rpm: Bool) -> Double? {
        let raw = rpm ? (side == .left ? leftPumpRpm : rightPumpRpm) : (side == .left ? leftFlowrateCd : rightFlowrateCd)
        guard let raw, raw.isFinite else { return nil }
        return rpm ? raw : raw / 100
    }
}

enum SensorObservation {
    static func date(_ string: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string))
            ?? (try? Date.ISO8601FormatStyle().parse(string))
    }
    static func fresh(_ date: Date?, age: Double = 90, now: Date = .now) -> Bool {
        guard let date else { return false }
        return (0...age).contains(now.timeIntervalSince(date))
    }
    static func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
}

struct SensorTrendPoint: Identifiable, Sendable, Equatable {
    let time: Date
    let value: Double
    let series: String
    let segment: Int
    var id: String { "\(series)-\(segment)-\(time.timeIntervalSince1970)" }
    var run: String { "\(series)-\(segment)" }

    func temperature(fahrenheit: Bool) -> Self {
        .init(time: time, value: fahrenheit ? value * 9 / 5 + 32 : value, series: series, segment: segment)
    }

    // Preserve explicit missing values and long sampling gaps; never interpolate across either.
    static func series(_ name: String, values: [(Date, Double?)], maximumGap: Double = 600) -> [Self] {
        var result: [Self] = [], segment = 0
        var previous: Date?
        for (date, value) in values.sorted(by: { $0.0 < $1.0 }) {
            guard let value = SensorObservation.finite(value) else { segment += 1; previous = nil; continue }
            if let previous, date.timeIntervalSince(previous) > maximumGap { segment += 1 }
            result.append(.init(time: date, value: value, series: name, segment: segment))
            previous = date
        }
        let width = max(1, Int(ceil(Double(result.count) / 240)))
        guard width > 1 else { return result }
        return stride(from: 0, to: result.count, by: width).flatMap { offset -> [Self] in
            let bucket = Array(result[offset..<min(result.count, offset + width)])
            return Dictionary(grouping: bucket, by: \.segment).values.flatMap { run -> [Self] in
                let candidates = [run.first, run.min { $0.value < $1.value }, run.max { $0.value < $1.value }, run.last].compactMap { $0 }
                return Dictionary(grouping: candidates, by: \.id).values.compactMap(\.first)
            }.sorted { $0.time < $1.time }
        }
    }
}
