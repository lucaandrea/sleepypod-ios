import Foundation

/// Presentation preserves complete source intervals and never converts presence into sleep.
enum PersonalHistoryPresentation {
    static func date(_ milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000).formatted(.dateTime.year().month(.abbreviated).day().hour().minute().second())
    }
    static func number(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "Unavailable"
    }
    static func duration(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }
    static func mode(_ value: PersonalHistoryRecord.Attribution.Mode) -> String {
        value == .soloMerged ? "Solo arrangement" : "Assigned arrangement"
    }
    static func summary(_ payload: PersonalHistoryPayload) -> String {
        switch payload {
        case let .presence(seconds, exits): "Reported in bed: \(duration(seconds)) · Exits: \(exits)"
        case let .vitals(heartRate, _, _, _): "Heart rate: \(number(heartRate))\(heartRate == nil ? "" : " bpm")"
        case let .movement(total): "Movement total: \(number(total))"
        }
    }
}
