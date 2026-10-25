import Foundation

/// Presentation only: every controller request still uses a whole-Fahrenheit setpoint.
enum TemperatureDisplay: String, Codable, CaseIterable, Identifiable, Sendable {
    case degrees, offset, eightSleep
    var id: String { rawValue }
    var title: String {
        switch self {
        case .degrees: "Degrees"
        case .offset: "Offset"
        case .eightSleep: "Eight Sleep"
        }
    }

    static func level(for fahrenheit: Double) -> Int {
        guard fahrenheit.isFinite else { return 0 }
        return max(-10, min(10, Int(floor((fahrenheit - 82.5) / 2.75 + 0.5))))
    }
    static func fahrenheit(forLevel level: Int) -> Int {
        Int(floor(82.5 + Double(max(-10, min(10, level))) * 2.75 + 0.5))
    }
    func text(_ fahrenheit: Int, unit: TemperatureFormat, includeUnit: Bool = false) -> String {
        switch self {
        case .degrees:
            if includeUnit { return TemperatureConversion.displayTemp(fahrenheit, format: unit.degreeUnit) }
            return TemperatureConversion.valueText(fahrenheit, format: unit.degreeUnit)
        case .offset: return TemperatureConversion.offsetDisplay(fahrenheit - 80)
        case .eightSleep: return TemperatureConversion.offsetDisplay(Self.level(for: Double(fahrenheit)))
        }
    }
    func step(_ fahrenheit: Int, by delta: Int, unit: TemperatureFormat) -> Int {
        if self == .eightSleep { return Self.fahrenheit(forLevel: Self.level(for: Double(fahrenheit)) + delta) }
        let increment = Double(delta) * (unit == .celsius ? 1.8 : 1)
        return max(55, min(110, Int(floor(Double(fahrenheit) + increment + 0.5))))
    }
    func target(at fraction: Double) -> Int {
        let bounded = min(1, max(0, fraction))
        if self == .eightSleep { return Self.fahrenheit(forLevel: Int(floor(-10 + bounded * 20 + 0.5))) }
        return Int(floor(55 + bounded * 55 + 0.5))
    }
}

extension TemperatureFormat {
    /// Sensor measurements never use a relative comfort scale.
    var degreeUnit: Self { self == .celsius ? .celsius : .fahrenheit }
}

enum TemperatureLayout: String, CaseIterable, Identifiable, Sendable {
    case cards, stage
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum StageZoneVisibility: String, CaseIterable, Identifiable, Sendable {
    case selected, always, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .selected: "On selection"
        case .always: "Always"
        case .off: "Off"
        }
    }
}
