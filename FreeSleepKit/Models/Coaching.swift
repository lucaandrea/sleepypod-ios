import Foundation

struct Coaching: Codable, Sendable {
    var headline: String
    var observations: [String]
    var suggestions: [String]
    var limitations: [String]
    var provider: String
    var model: String
    var grounding: CoachGrounding? = nil
}
