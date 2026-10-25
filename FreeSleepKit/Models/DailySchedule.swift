import Foundation

struct DailySchedule: Codable, Sendable, Equatable {
    struct Power: Codable, Sendable, Equatable {
        var on: String; var off: String; var onTemperature: Int; var enabled: Bool
    }
    struct Alarm: Codable, Sendable, Equatable {
        var time: String; var enabled: Bool; var alarmTemperature: Int
        var vibrationIntensity: Int; var vibrationPattern: String; var duration: Int
    }
    var temperatures: [String: Int]
    var alarm: Alarm
    var power: Power
    static let empty = DailySchedule(temperatures: [:],
        alarm: Alarm(time: "07:00", enabled: false, alarmTemperature: 82, vibrationIntensity: 30, vibrationPattern: "rise", duration: 60),
        power: Power(on: "22:00", off: "08:00", onTemperature: 80, enabled: false))
}
