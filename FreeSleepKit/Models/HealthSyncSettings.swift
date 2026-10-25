import Foundation

struct HealthSyncSettings: Codable, Sendable, Equatable {
    var podID: String
    var side: BedSide
    var exportHeartRate: Bool
    var automatic: Bool
    var lastSuccess: Date?
    var lastAttempt: Date?
    var lastSampleCount: Int?
}
