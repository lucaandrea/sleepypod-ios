import Foundation

struct BaseStatus: Codable, Sendable, Equatable {
    struct Angles: Codable, Sendable, Equatable { var head: Double; var feet: Double }
    struct Position: Codable, Sendable, Equatable { var left: Angles; var right: Angles }
    var state: String
    var position: Position?
    var updatedAt: Double?
    var stale: Bool
    var busy: Bool
    var error: String?
    var ready: Bool { state == "connected" && !stale && !busy }
}
