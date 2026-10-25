import Foundation

struct DataCoverage: Codable, Sendable, Equatable {
    struct Day: Codable, Sendable, Equatable, Identifiable {
        var date: String
        var status: String
        var id: String { date }
        var label: String {
            switch status {
            case "known": "Known presence"
            case "unknown": "Presence unknown"
            case "not_returned": "No record returned"
            default: "Coverage unknown"
            }
        }
    }
    struct Window: Codable, Sendable, Equatable {
        var from: String
        var through: String
        var days: [Day]
        var recordedNights: Int
        var presenceNights: Int
        var heartRateNights: Int
        var hrvNights: Int
        var respiratoryRateNights: Int
    }
    var version: Int
    var minimumNights: Int
    var recent: Window?
    var previous: Window?
    var comparisonAvailable: Bool
    var comparisonReason: String
    var excludedEpisodes: Int
    var scopeNote: String
}
