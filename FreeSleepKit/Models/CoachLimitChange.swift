import Foundation

struct CoachLimitChange: Codable, Sendable, Equatable {
    var monthlyLimit: Int
    var originalRevision: Int
}
