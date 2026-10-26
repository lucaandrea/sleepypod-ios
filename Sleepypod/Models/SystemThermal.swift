import Foundation

enum ThermalRange: String, CaseIterable, Identifiable, Sendable {
    case live, hour = "1h", twelveHours = "12h", day = "24h", week = "7d"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: "Live"
        case .hour: "1 hour"
        case .twelveHours: "12 hours"
        case .day: "24 hours"
        case .week: "7 days"
        }
    }
    var seconds: Double {
        switch self {
        case .live: 1800
        case .hour: 3600
        case .twelveHours: 43200
        case .day: 86400
        case .week: 604800
        }
    }
}

struct SystemThermalSnapshot: Decodable, Sendable {
    struct BedSide: Decodable, Sendable, Identifiable {
        let side: Side
        let isPowered: Bool
        let targetTempF: Double?
        let currentTempF: Double?
        let isAlarmVibrating: Bool
        let poweredOnAt: String?
        let pumpRpm: Double?
        let flowrate: Double?
        let readingAgeSec: Double?
        let waterTempF: Double?
        let bedSurfaceTempF: Double?
        let guardBlocked: Bool
        let verdict: String
        let note: String?
        var id: Side { side }
        var direction: String {
            guard verdict == "delivering", isPowered, let targetTempF, let currentTempF else { return verdict.capitalized }
            if targetTempF < currentTempF - 0.5 { return "Cooling" }
            if targetTempF > currentTempF + 0.5 { return "Warming" }
            return "Holding"
        }
    }
    let pumpStallProtectionEnabled: Bool
    let reportsPumpSpeed: Bool?
    let heatsinkTempF: Double?
    let ambientTempF: Double?
    let sides: [BedSide]

    func point(at now: Date) -> ThermalHistoryPoint {
        var values: [ThermalSignal: Double] = [:]
        for side in sides {
            let left = side.side == .left
            if side.isPowered {
                values[left ? .leftBed : .rightBed] = side.currentTempF
                values[left ? .leftTarget : .rightTarget] = side.targetTempF
            }
            values[left ? .leftWater : .rightWater] = side.waterTempF
            values[left ? .leftSurface : .rightSurface] = side.bedSurfaceTempF
            values[left ? .leftRpm : .rightRpm] = side.pumpRpm
        }
        values[.heatsink] = heatsinkTempF; values[.ambient] = ambientTempF
        return .init(timestamp: now.timeIntervalSince1970 * 1000, values: values.filter { $0.value.isFinite })
    }
}

enum ThermalSignal: String, CaseIterable, Sendable {
    case leftBed, rightBed, leftTarget, rightTarget, leftWater, rightWater, leftSurface, rightSurface, leftRpm, rightRpm, heatsink, ambient
    var side: Side? { rawValue.hasPrefix("left") ? .left : rawValue.hasPrefix("right") ? .right : nil }
    var target: Bool { self == .leftTarget || self == .rightTarget }
    var title: String {
        switch self {
        case .leftBed: "Left bed"
        case .rightBed: "Right bed"
        case .leftTarget: "Left target"
        case .rightTarget: "Right target"
        case .leftWater: "Left water"
        case .rightWater: "Right water"
        case .leftSurface: "Left surface"
        case .rightSurface: "Right surface"
        case .leftRpm: "Left pump"
        case .rightRpm: "Right pump"
        case .heatsink: "Heatsink"
        case .ambient: "Ambient"
        }
    }
}

enum ThermalPanel: String, CaseIterable, Identifiable, Sendable {
    case bedTarget, water, surface, pump, hub
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bedTarget: "Bed and target"
        case .water: "Water"
        case .surface: "Surface"
        case .pump: "Pump rpm"
        case .hub: "Hub"
        }
    }
    var signals: [ThermalSignal] {
        switch self {
        case .bedTarget: [.leftBed, .rightBed, .leftTarget, .rightTarget]
        case .water: [.leftWater, .rightWater]
        case .surface: [.leftSurface, .rightSurface]
        case .pump: [.leftRpm, .rightRpm]
        case .hub: [.heatsink, .ambient]
        }
    }
}

struct ThermalHistoryPoint: Decodable, Sendable {
    let timestamp: Double
    let values: [ThermalSignal: Double]
    init(timestamp: Double, values: [ThermalSignal: Double]) { self.timestamp = timestamp; self.values = values }
    private struct Key: CodingKey { let stringValue: String; var intValue: Int? { nil }; init?(intValue: Int) { return nil }; init(stringValue: String) { self.stringValue = stringValue } }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        timestamp = try fields.decode(Double.self, forKey: .init(stringValue: "t"))
        var values: [ThermalSignal: Double] = [:]
        for signal in ThermalSignal.allCases {
            if let value = try? fields.decode(Double.self, forKey: .init(stringValue: signal.rawValue)), value.isFinite { values[signal] = value }
        }
        self.values = values
    }
}

struct SystemThermalHistory: Decodable, Sendable {
    struct PowerOn: Decodable, Sendable { let side: Side; let at: Double }
    let range: String
    let from: Double
    let to: Double
    let bucketSec: Double
    let points: [ThermalHistoryPoint]
    let powerOn: [PowerOn]
    let available: [String: Bool]
    let bedTargetSince: Double?
}

struct ThermalChartData: Sendable {
    struct Sample: Sendable, Identifiable {
        let id: String
        let time: Double
        let value: Double
        let signal: ThermalSignal
        let segment: Int
    }
    let from: Double
    let to: Double
    let gap: Double
    let points: [ThermalHistoryPoint]
    let powerOn: [SystemThermalHistory.PowerOn]
    let available: [String: Bool]
    let bedTargetSince: Double?
    // A missing value or a long gap starts a new line; disconnected readings are never interpolated.
    func samples(_ panel: ThermalPanel, celsius: Bool) -> [Sample] {
        panel.signals.flatMap { signal in
            var previous: Double?, segment = 0
            return points.enumerated().compactMap { index, point -> Sample? in
                guard let value = point.values[signal] else { previous = nil; return nil }
                if previous == nil || point.timestamp - previous! > gap { segment += 1 }
                previous = point.timestamp
                return .init(id: "\(signal.rawValue):\(index)", time: point.timestamp, value: panel != .pump && celsius ? (value - 32) * 5 / 9 : value, signal: signal, segment: segment)
            }
        }
    }
    func nearest(at time: Double) -> ThermalHistoryPoint? {
        guard let nearest = points.min(by: { abs($0.timestamp - time) < abs($1.timestamp - time) }), abs(nearest.timestamp - time) <= gap else { return nil }
        return nearest
    }
}
