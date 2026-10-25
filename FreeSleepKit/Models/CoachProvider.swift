import Foundation

struct CoachProvider: Codable, Sendable, Identifiable {
    var provider: String
    var model: String
    var configured: Bool
    var id: String { provider }
}
