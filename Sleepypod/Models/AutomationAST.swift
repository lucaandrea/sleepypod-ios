import Foundation

/// Core's persisted rule language. Tagged encoding keeps edits compatible with the web editor.
indirect enum AutomationExpression: Codable, Equatable, Sendable {
    case literal(Double)
    case signal(String)
    case window(function: String, signal: String, minutes: Int)
    case binary(operation: String, left: Self, right: Self)
    case clamp(value: Self, minimum: Self, maximum: Self)

    private enum CodingKeys: String, CodingKey { case kind, value, signal, fn, lastMin, op, left, right, min, max }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        switch try fields.decode(String.self, forKey: .kind) {
        case "literal": self = .literal(try fields.decode(Double.self, forKey: .value))
        case "signal": self = .signal(try fields.decode(String.self, forKey: .signal))
        case "window": self = .window(function: try fields.decode(String.self, forKey: .fn), signal: try fields.decode(String.self, forKey: .signal), minutes: try fields.decode(Int.self, forKey: .lastMin))
        case "binary": self = .binary(operation: try fields.decode(String.self, forKey: .op), left: try fields.decode(Self.self, forKey: .left), right: try fields.decode(Self.self, forKey: .right))
        case "clamp": self = .clamp(value: try fields.decode(Self.self, forKey: .value), minimum: try fields.decode(Self.self, forKey: .min), maximum: try fields.decode(Self.self, forKey: .max))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: fields, debugDescription: "This controller uses an unsupported automation expression.")
        }
    }
    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .literal(let value): try fields.encode("literal", forKey: .kind); try fields.encode(value, forKey: .value)
        case .signal(let signal): try fields.encode("signal", forKey: .kind); try fields.encode(signal, forKey: .signal)
        case .window(let function, let signal, let minutes):
            try fields.encode("window", forKey: .kind); try fields.encode(function, forKey: .fn)
            try fields.encode(signal, forKey: .signal); try fields.encode(minutes, forKey: .lastMin)
        case .binary(let operation, let left, let right):
            try fields.encode("binary", forKey: .kind); try fields.encode(operation, forKey: .op)
            try fields.encode(left, forKey: .left); try fields.encode(right, forKey: .right)
        case .clamp(let value, let minimum, let maximum):
            try fields.encode("clamp", forKey: .kind); try fields.encode(value, forKey: .value)
            try fields.encode(minimum, forKey: .min); try fields.encode(maximum, forKey: .max)
        }
    }
    var summary: String {
        switch self {
        case .literal(let value): value.formatted(.number.precision(.fractionLength(0...2)))
        case .signal(let signal): AutomationSignal.label(signal)
        case .window(let function, let signal, let minutes): "\(function) \(AutomationSignal.label(signal)) over \(minutes) min"
        case .binary(let operation, let left, let right): "(\(left.summary) \(operation) \(right.summary))"
        case .clamp(let value, let minimum, let maximum): "\(value.summary), limited to \(minimum.summary)–\(maximum.summary)"
        }
    }
    var signals: Set<String> {
        switch self {
        case .literal: []
        case .signal(let signal), .window(_, let signal, _): [signal]
        case .binary(_, let left, let right): left.signals.union(right.signals)
        case .clamp(let value, let minimum, let maximum): value.signals.union(minimum.signals).union(maximum.signals)
        }
    }
    func valid(depth: Int = 1) -> Bool {
        guard depth <= 16 else { return false }
        switch self {
        case .literal(let value): return value.isFinite
        case .signal(let signal): return AutomationSignal.validKey(signal)
        case .window(let function, let signal, let minutes):
            return ["avg", "min", "max", "sum", "count"].contains(function) && AutomationSignal.validKey(signal) && (1...1440).contains(minutes)
        case .binary(let operation, let left, let right):
            return ["+", "-", "*", "/"].contains(operation) && left.valid(depth: depth + 1) && right.valid(depth: depth + 1)
                && !(operation == "/" && right == .literal(0))
        case .clamp(let value, let minimum, let maximum):
            return value.valid(depth: depth + 1) && minimum.valid(depth: depth + 1) && maximum.valid(depth: depth + 1)
        }
    }
    var nodeCount: Int {
        switch self {
        case .literal, .signal, .window: 1
        case .binary(_, let left, let right): 1 + left.nodeCount + right.nodeCount
        case .clamp(let value, let minimum, let maximum): 1 + value.nodeCount + minimum.nodeCount + maximum.nodeCount
        }
    }
}

indirect enum AutomationCondition: Codable, Equatable, Sendable {
    case all([Self]), any([Self]), not(Self)
    case compare(operation: String, left: AutomationExpression, right: AutomationExpression)
    case between(subject: AutomationExpression, minimum: AutomationExpression, maximum: AutomationExpression)
    case time(start: String, end: String)
    case days([DayOfWeek])
    private enum CodingKeys: String, CodingKey { case kind, conditions, condition, op, left, right, subject, min, max, start, end, days }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        switch try fields.decode(String.self, forKey: .kind) {
        case "and": self = .all(try fields.decode([Self].self, forKey: .conditions))
        case "or": self = .any(try fields.decode([Self].self, forKey: .conditions))
        case "not": self = .not(try fields.decode(Self.self, forKey: .condition))
        case "compare": self = .compare(operation: try fields.decode(String.self, forKey: .op), left: try fields.decode(AutomationExpression.self, forKey: .left), right: try fields.decode(AutomationExpression.self, forKey: .right))
        case "between": self = .between(subject: try fields.decode(AutomationExpression.self, forKey: .subject), minimum: try fields.decode(AutomationExpression.self, forKey: .min), maximum: try fields.decode(AutomationExpression.self, forKey: .max))
        case "timeBetween": self = .time(start: try fields.decode(String.self, forKey: .start), end: try fields.decode(String.self, forKey: .end))
        case "onDays": self = .days(try fields.decode([DayOfWeek].self, forKey: .days))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: fields, debugDescription: "This controller uses an unsupported automation condition.")
        }
    }
    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all(let conditions): try fields.encode("and", forKey: .kind); try fields.encode(conditions, forKey: .conditions)
        case .any(let conditions): try fields.encode("or", forKey: .kind); try fields.encode(conditions, forKey: .conditions)
        case .not(let condition): try fields.encode("not", forKey: .kind); try fields.encode(condition, forKey: .condition)
        case .compare(let operation, let left, let right):
            try fields.encode("compare", forKey: .kind); try fields.encode(operation, forKey: .op)
            try fields.encode(left, forKey: .left); try fields.encode(right, forKey: .right)
        case .between(let subject, let minimum, let maximum):
            try fields.encode("between", forKey: .kind); try fields.encode(subject, forKey: .subject)
            try fields.encode(minimum, forKey: .min); try fields.encode(maximum, forKey: .max)
        case .time(let start, let end): try fields.encode("timeBetween", forKey: .kind); try fields.encode(start, forKey: .start); try fields.encode(end, forKey: .end)
        case .days(let days): try fields.encode("onDays", forKey: .kind); try fields.encode(days, forKey: .days)
        }
    }
    var summary: String {
        switch self {
        case .all(let conditions): conditions.isEmpty ? "Always" : conditions.map(\.summary).joined(separator: " and ")
        case .any(let conditions): conditions.isEmpty ? "Never" : "(" + conditions.map(\.summary).joined(separator: " or ") + ")"
        case .not(let condition): "not (\(condition.summary))"
        case .compare(let operation, let left, let right): "\(left.summary) \(operation) \(right.summary)"
        case .between(let subject, let minimum, let maximum): "\(subject.summary) is between \(minimum.summary) and \(maximum.summary)"
        case .time(let start, let end): "between \(start) and \(end)"
        case .days(let days): days.map { $0.rawValue.capitalized }.joined(separator: ", ")
        }
    }
    var signals: Set<String> {
        switch self {
        case .all(let children), .any(let children): children.reduce(into: []) { $0.formUnion($1.signals) }
        case .not(let child): child.signals
        case .compare(_, let left, let right): left.signals.union(right.signals)
        case .between(let subject, let minimum, let maximum): subject.signals.union(minimum.signals).union(maximum.signals)
        case .time, .days: []
        }
    }
    func valid(depth: Int = 1) -> Bool {
        guard depth <= 16 else { return false }
        switch self {
        case .all(let conditions), .any(let conditions): return conditions.count <= 24 && conditions.allSatisfy { $0.valid(depth: depth + 1) }
        case .not(let condition): return condition.valid(depth: depth + 1)
        case .compare(let operation, let left, let right):
            return [">", ">=", "<", "<=", "==", "!="].contains(operation) && left.valid(depth: depth + 1) && right.valid(depth: depth + 1)
        case .between(let subject, let minimum, let maximum): return subject.valid(depth: depth + 1) && minimum.valid(depth: depth + 1) && maximum.valid(depth: depth + 1)
        case .time(let start, let end): return Self.validClock(start) && Self.validClock(end)
        case .days(let days): return !days.isEmpty
        }
    }
    static func validClock(_ value: String) -> Bool {
        guard value.range(of: "^[0-9]{2}:[0-9]{2}$", options: .regularExpression) != nil else { return false }
        let parts = value.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 && (0...23).contains(parts[0]) && (0...59).contains(parts[1])
    }
    var nodeCount: Int {
        switch self {
        case .all(let children), .any(let children): 1 + children.reduce(0) { $0 + $1.nodeCount }
        case .not(let child): 1 + child.nodeCount
        case .compare(_, let left, let right): 1 + left.nodeCount + right.nodeCount
        case .between(let subject, let minimum, let maximum): 1 + subject.nodeCount + minimum.nodeCount + maximum.nodeCount
        case .time, .days: 1
        }
    }
}

struct AutomationTrigger: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable { case tick, signalChange, timeOfDay }
    var kind: Kind = .tick
    var everyMin: Int? = 1
    var signal: String?
    var at: String?
    var days: [DayOfWeek]?
    private enum CodingKeys: CodingKey { case kind, everyMin, signal, at, days }
    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(kind, forKey: .kind)
        switch kind {
        case .tick: try fields.encodeIfPresent(everyMin, forKey: .everyMin)
        case .signalChange: try fields.encodeIfPresent(signal, forKey: .signal)
        case .timeOfDay: try fields.encodeIfPresent(at, forKey: .at); try fields.encodeIfPresent(days, forKey: .days)
        }
    }
    var valid: Bool {
        switch kind {
        case .tick: everyMin.map { (1...1440).contains($0) } ?? false
        case .signalChange: signal.map(AutomationSignal.validKey) ?? false
        case .timeOfDay: at.map(AutomationCondition.validClock) == true && (days == nil || days?.isEmpty == false)
        }
    }
    var summary: String {
        switch kind {
        case .tick: "Every \(everyMin ?? 1) min"
        case .signalChange: "When \(signal.map(AutomationSignal.label) ?? "signal") changes"
        case .timeOfDay: "At \(at ?? "—")"
        }
    }
}

struct AutomationAction: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable { case setTemperature, setPower, notify }
    struct Clamp: Codable, Equatable, Sendable { var min: Double; var max: Double }
    var kind: Kind
    var message: String?
    var side: Side?
    var temp: AutomationExpression?
    var clamp: Clamp?
    var durationSec: Int?
    var on: Bool?
    var mode: String?
    var holdMinutes: Int?
    private enum CodingKeys: CodingKey { case kind, message, side, temp, clamp, durationSec, on, mode, holdMinutes }
    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(kind, forKey: .kind)
        if kind == .notify { try fields.encodeIfPresent(message, forKey: .message); return }
        try fields.encodeIfPresent(side, forKey: .side)
        try fields.encodeIfPresent(temp, forKey: .temp)
        try fields.encodeIfPresent(mode, forKey: .mode)
        try fields.encodeIfPresent(holdMinutes, forKey: .holdMinutes)
        if kind == .setPower { try fields.encodeIfPresent(on, forKey: .on) }
        else { try fields.encodeIfPresent(clamp, forKey: .clamp); try fields.encodeIfPresent(durationSec, forKey: .durationSec) }
    }
    var valid: Bool {
        switch kind {
        case .notify: return message.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 280 } ?? false
        case .setTemperature: guard temp?.valid() == true else { return false }
        case .setPower: guard on != nil, temp?.valid() ?? true else { return false }
        }
        if let clamp, !(clamp.min.isFinite && clamp.max.isFinite && clamp.min >= 55 && clamp.max <= 110 && clamp.min <= clamp.max && clamp.min.rounded() == clamp.min && clamp.max.rounded() == clamp.max) { return false }
        if let durationSec, !(0...86400).contains(durationSec) { return false }
        if let holdMinutes, !(1...1440).contains(holdMinutes) { return false }
        return mode == nil || ["policy", "one-shot"].contains(mode)
    }
    var summary: String {
        switch kind {
        case .notify: return "Notify: \(message ?? "")"
        case .setPower:
            let temperature = temp.map { " at " + $0.summary + "°F" } ?? ""
            return "Turn power \(on == true ? "on" : "off")\(temperature)\(side.map { " on " + $0.rawValue } ?? "")\(controlSummary)"
        case .setTemperature:
            let bounds = clamp.map { " · \($0.min.formatted())–\($0.max.formatted())°F" } ?? ""
            let revert = durationSec.flatMap { seconds -> String? in
                guard seconds > 0 else { return nil }
                return " · revert after " + (seconds.isMultiple(of: 60) ? "\(seconds / 60) min" : "\(seconds) sec")
            } ?? ""
            return "Set \(temp?.summary ?? "—")°F\(side.map { " on " + $0.rawValue } ?? "")\(bounds)\(revert)\(controlSummary)"
        }
    }
    private var controlSummary: String {
        (mode.map { " · " + $0 } ?? "") + (holdMinutes.map { " · hold \($0) min" } ?? "")
    }

}

struct AutomationSignal: Identifiable, Sendable {
    let id: String
    let title: String
    let unit: String
    var liveOnly = false
    static let catalog: [Self] = [
        .init(id: "ambient.temperature", title: "Room temperature", unit: "°F"),
        .init(id: "ambient.humidity", title: "Humidity", unit: "%"),
        .init(id: "ambient.light", title: "Light", unit: "lux"),
        .init(id: "{side}.currentTemperature", title: "Current temperature", unit: "°F"),
        .init(id: "{side}.targetTemperature", title: "Target temperature", unit: "°F"),
        .init(id: "{side}.surfaceTemp", title: "Bed surface", unit: "°F"),
        .init(id: "{side}.surfaceTemp.spread", title: "Surface spread", unit: "°F"),
        .init(id: "{side}.surfaceTemp.gradient", title: "Surface gradient", unit: "°F"),
        .init(id: "{side}.waterTemp", title: "Water temperature", unit: "°F"),
        .init(id: "{side}.movement", title: "Movement", unit: ""),
        .init(id: "{side}.heartRate", title: "Heart rate", unit: "bpm"),
        .init(id: "{side}.hrv", title: "HRV", unit: "ms"),
        .init(id: "{side}.breathingRate", title: "Breathing", unit: "br/min"),
        .init(id: "{side}.presence", title: "Person in bed", unit: "0 or 1", liveOnly: true),
        .init(id: "{side}.presence.zones", title: "Occupied zones", unit: "zones", liveOnly: true),
        .init(id: "{side}.cap.max", title: "Bed pressure peak", unit: ""),
        .init(id: "{side}.cap.mean", title: "Bed pressure average", unit: ""),
        .init(id: "{side}.cap.spread", title: "Pressure spread", unit: ""),
        .init(id: "water.low", title: "Water low", unit: "0 or 1")
    ]
    static func concrete(_ key: String, side: Side?) -> String { key.replacingOccurrences(of: "{side}", with: side?.rawValue ?? "left") }
    static func label(_ key: String) -> String {
        let template = key.replacingOccurrences(of: "^(left|right)\\.", with: "{side}.", options: .regularExpression)
        let title = catalog.first { $0.id == template }?.title ?? key
        return key.hasPrefix("left.") ? "Left \(title.lowercased())" : key.hasPrefix("right.") ? "Right \(title.lowercased())" : title
    }
    static func display(_ value: Double?, key: String) -> String {
        guard let value, value.isFinite else { return "Missing" }
        let template = key.replacingOccurrences(of: "^(left|right)\\.", with: "{side}.", options: .regularExpression)
        let unit = catalog.first { $0.id == template }?.unit ?? ""
        if unit == "0 or 1", value == 0 || value == 1 { return value == 1 ? "Yes" : "No" }
        return value.formatted(.number.precision(.fractionLength(0...2))) + (unit.isEmpty ? "" : " " + unit)
    }
    static func validKey(_ key: String) -> Bool { key.range(of: "^[a-z][a-z0-9]*(\\.[a-z0-9]+)*$", options: [.regularExpression, .caseInsensitive]) != nil }
}
