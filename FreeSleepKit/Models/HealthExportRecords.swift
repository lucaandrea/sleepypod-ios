import Foundation

struct HealthExportRecords: Decodable, Sendable {
    struct Sleep: Decodable, Sendable, Identifiable {
        var id: Int
        var present_intervals: [[String]]
        var valid: Bool? = nil
    }
    struct Vital: Decodable, Sendable, Identifiable {
        var id: Int
        var timestamp: String
        var heart_rate: Double?
    }
    struct Identity: Decodable, Sendable { var id: String }
}
