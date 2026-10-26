import Foundation

enum CoverTap: String, Codable, Sendable, CaseIterable, Identifiable {
    case doubleTap, tripleTap, quadTap
    var id: String { rawValue }
    var title: String {
        switch self {
        case .doubleTap: "Double tap"
        case .tripleTap: "Triple tap"
        case .quadTap: "Quad tap"
        }
    }
    var count: Int {
        switch self {
        case .doubleTap: 2
        case .tripleTap: 3
        case .quadTap: 4
        }
    }
}
struct GestureBinding: Codable, Sendable, Equatable {
    let side: Side
    let tapType: CoverTap
    let actionType: String
    let temperatureChange: String?
    let temperatureAmount: Int?
    let alarmBehavior: String?
    let alarmSnoozeDuration: Int?
    let alarmInactiveBehavior: String?
    var idleDescription: String {
        if actionType == "temperature" { return temperatureDescription }
        guard actionType == "alarm" else { return "Unsupported action" }
        return alarmInactiveBehavior == "power" ? "Power on / off" : "Nothing"
    }
    var ringingDescription: String {
        if actionType == "temperature" { return temperatureDescription }
        guard actionType == "alarm" else { return "Unsupported action" }
        return alarmBehavior == "snooze" ? "Snooze" : "Stop alarm"
    }
    private var temperatureDescription: String {
        guard let temperatureAmount, ["increment", "decrement"].contains(temperatureChange) else { return "Incomplete temperature action" }
        return "Temperature \(temperatureChange == "increment" ? "+" : "−")\(temperatureAmount)°F"
    }
}
struct GestureBindingsSnapshot: Decodable, Sendable {
    struct Names: Decodable, Sendable {
        struct Profile: Decodable, Sendable { let name: String }
        let left: Profile
        let right: Profile
        func name(_ side: Side) -> String { side == .left ? left.name : right.name }
    }
    struct Bindings: Decodable, Sendable {
        var left: [GestureBinding]
        var right: [GestureBinding]
        func binding(_ side: Side, tap: CoverTap) -> GestureBinding? { (side == .left ? left : right).first { $0.tapType == tap } }
        mutating func set(_ value: GestureBinding?, side: Side, tap: CoverTap) {
            if side == .left { left.removeAll { $0.tapType == tap }; if let value { left.append(value) } }
            else { right.removeAll { $0.tapType == tap }; if let value { right.append(value) } }
        }
    }
    let sides: Names
    var gestures: Bindings
    static let demo = Self(sides: .init(left: .init(name: "Alex"), right: .init(name: "Sam")), gestures: .init(left: [], right: []))
}
struct GestureDraft: Identifiable, Sendable, Equatable {
    let side: Side
    let tap: CoverTap
    var actionType: String
    var temperatureChange: String
    var temperatureAmount: Int
    var alarmBehavior: String
    var alarmSnoozeDuration: Int?
    var alarmInactiveBehavior: String
    var id: String { "\(side.rawValue)-\(tap.rawValue)" }
    init(side: Side, tap: CoverTap, original: GestureBinding?) {
        self.side = side; self.tap = tap
        actionType = original?.actionType ?? "temperature"
        temperatureChange = original?.temperatureChange ?? "increment"
        temperatureAmount = original?.temperatureAmount ?? 2
        alarmBehavior = original?.alarmBehavior ?? "snooze"
        alarmSnoozeDuration = original?.alarmSnoozeDuration
        alarmInactiveBehavior = original?.alarmInactiveBehavior ?? "none"
    }
    var issue: String? {
        if actionType == "temperature" {
            return ["increment", "decrement"].contains(temperatureChange) && (0...10).contains(temperatureAmount) ? nil : "Choose a change from 0–10°F."
        }
        if actionType == "alarm" {
            return ["snooze", "dismiss"].contains(alarmBehavior) && ["power", "none"].contains(alarmInactiveBehavior) && (alarmSnoozeDuration.map { (60...600).contains($0) } ?? true) ? nil : "Reload to read supported alarm behavior."
        }
        return "Choose temperature or alarm."
    }
    var fields: [String: SettingsFieldValue] {
        var values: [String: SettingsFieldValue] = ["side": .string(side.rawValue), "tapType": .string(tap.rawValue), "actionType": .string(actionType)]
        if actionType == "temperature" {
            values["temperatureChange"] = .string(temperatureChange); values["temperatureAmount"] = .integer(temperatureAmount)
        } else if actionType == "alarm" {
            values["alarmBehavior"] = .string(alarmBehavior); values["alarmInactiveBehavior"] = .string(alarmInactiveBehavior)
            if let alarmSnoozeDuration { values["alarmSnoozeDuration"] = .integer(alarmSnoozeDuration) }
        }
        return values
    }
    var binding: GestureBinding { .init(side: side, tapType: tap, actionType: actionType, temperatureChange: temperatureChange, temperatureAmount: temperatureAmount, alarmBehavior: alarmBehavior, alarmSnoozeDuration: alarmSnoozeDuration, alarmInactiveBehavior: alarmInactiveBehavior) }
}
