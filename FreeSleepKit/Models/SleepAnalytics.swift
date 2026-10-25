import Foundation

struct SleepAnalytics: Codable, Sendable, Equatable {
    struct Night: Codable, Sendable, Identifiable, Equatable {
        var id: Int
        var date: String
        var startedAt: String
        var endedAt: String
        var occupiedMinutes: Double?
        var heartRate: Double?
        var hrv: Double?
        var respiratoryRate: Double?
        var exits: Int
        var windowMinutes: Double? = nil
    }
    struct Summary: Codable, Sendable, Equatable {
        var recordedNights: Int
        var averageOccupiedMinutes: Double?
        var averageHeartRate: Double?
        var averageHrv: Double?
        var averageRespiratoryRate: Double?
        var bedtimeVariationMinutes: Double?
        var weeklyChangeMinutes: Double?
    }
    struct Quality: Codable, Sendable, Equatable { var coverage: DataCoverage? }
    var quality: Quality? = nil
    var timeZone: String
    var nights: [Night]
    var episodes: [Night]? = nil
    var summary: Summary
    static func duration(_ minutes: Double?) -> String {
        guard let minutes else { return "—" }
        let rounded = Int(minutes.rounded())
        return "\(rounded / 60)h \(rounded % 60)m"
    }
}
