import Foundation

struct PodSettings: Codable, Sendable {
    struct Side: Codable, Sendable { var name: String; var awayMode: Bool }
    var id: String
    var timeZone: String
    var temperatureFormat: String
    var left: Side
    var right: Side
    subscript(side: BedSide) -> Side { side == .left ? left : right }
}
