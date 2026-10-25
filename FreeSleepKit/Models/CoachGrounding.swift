import Foundation

struct CoachGrounding: Codable, Sendable, Equatable {
    struct Fact: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var title: String
        var observation: String
        var context: String
        var sample: String
        var calculation: String
    }
    var version: Int
    var facts: [Fact]
    var suggestions: String
}
