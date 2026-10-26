import Foundation

struct PumpAlert: Decodable, Sendable, Identifiable, Equatable {
    let id: Int
    let timestamp: String
    let type: String
    let side: Side?
    let rpm: Double?
    let flowrateCd: Double?
    let durationSeconds: Double?
    let action: String
    let restoreTargetTemperature: Double?
    let restoreDurationSeconds: Double?
    let acknowledgedAt: String?
    let dismissedAt: String?
    var title: String {
        switch type {
        case "stall_left", "stall_right": "Pump stall"
        case "no_flow_left", "no_flow_right": "No flow"
        case "asymmetry": "Uneven flow"
        case "clog_suspected": "Possible clog"
        case "hub_temp_disputed": "Temperature disagreement"
        default: type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    var actionLabel: String {
        switch action {
        case "power_off": "Side powered off"
        case "auto_recovered": "Automatically recovered"
        case "warned": "Warning recorded"
        case "none": "No action recorded"
        default: action.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
    }
}
