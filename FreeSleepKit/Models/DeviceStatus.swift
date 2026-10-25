import Foundation

struct DeviceStatus: Codable, Sendable, Equatable {
    struct Side: Codable, Sendable, Equatable {
        var currentTemperatureF: Double
        var targetTemperatureF: Double
        var isOn: Bool
        var isAlarmVibrating: Bool?
    }
    var left: Side
    var right: Side
    var isPriming: Bool
    var waterLevel: String
    subscript(side: BedSide) -> Side { side == .left ? left : right }
}
