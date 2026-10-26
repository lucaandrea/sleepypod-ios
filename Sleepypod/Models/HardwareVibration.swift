import Foundation

enum HardwareVibrationPreset: String, CaseIterable, Identifiable, Sendable {
    case quick, standard, long, custom
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var duration: Int? {
        switch self {
        case .quick: 10
        case .standard: 30
        case .long: 60
        case .custom: nil
        }
    }
    var summary: String {
        switch self {
        case .quick: "Brief buzz"
        case .standard: "Default alarm"
        case .long: "Extended ramp"
        case .custom: "Custom duration"
        }
    }
}
struct HardwareVibrationRequest: Encodable, Sendable {
    let side: Side
    let duration: Int
    let vibrationIntensity = 100
    let vibrationPattern = "rise"
    func validate() throws {
        guard (1...60).contains(duration) else { throw APIError.notSupported("Vibration tests last between 1 and 60 seconds.") }
    }
}
