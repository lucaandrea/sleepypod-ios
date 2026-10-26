import Foundation

/// Core reports ownership separately from the hardware's power-off countdown.
struct TemperatureControlStatus: Codable, Sendable, Equatable {
    var source: String?
    var requestId: String?
    var targetTemperature: Double?
    var holdUntil: Double?
    var blocked: String?

    var holdDate: Date? { holdUntil.map { Date(timeIntervalSince1970: $0 / 1000) } }
    var title: String {
        if blocked == "safety" { return "Safety stop" }
        if blocked == "off" { return "Off" }
        switch source {
        case "schedule": return "On schedule"
        case "autopilot": return "Autopilot"
        case "run-once": return "Run-once session"
        case "manual": return "Manual hold"
        default: return "Manual"
        }
    }
}

struct SidePair<Value: Codable & Sendable>: Codable, Sendable {
    var left: Value?
    var right: Value?
    subscript(_ side: Side) -> Value? {
        get { side == .left ? left : right }
        set { if side == .left { left = newValue } else { right = newValue } }
    }
}

struct PumpStallNotice: Codable, Sendable {
    let alertId: Int
    let trippedAt: Double
    let rpm: Double
    let restore: Restore?
    struct Restore: Codable, Sendable {
        let targetTemperature: Double
        let durationSeconds: Double
    }
}
struct PrimeCompletion: Codable, Sendable {
    let timestamp: Double
    func isRecent(now: Date = .now) -> Bool {
        guard timestamp.isFinite else { return false }
        let seconds = timestamp > 1e12 ? timestamp / 1000 : timestamp
        let age = now.timeIntervalSince1970 - seconds
        return age >= 0 && age < 3600
    }
}
struct AlarmSnooze: Codable, Sendable {
    var active: Bool
    var snoozeUntil: Double?
}
struct RoomClimate: Codable, Sendable {
    let temperatureC: Double?
    let humidity: Double?
    let timestamp: Double?
}

struct TemperatureHold: Identifiable, Sendable {
    let minutes: Int
    var id: Int { minutes }
    var title: String { minutes < 60 ? "\(minutes) min" : "\(minutes / 60) hr" }
    static let options = [15, 30, 60, 120].map { Self(minutes: $0) }
}
