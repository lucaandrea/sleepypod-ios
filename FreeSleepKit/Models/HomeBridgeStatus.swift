import Foundation

struct HomeBridgeStatus: Decodable, Sendable {
    var enabled: Bool
    var running: Bool
    var pairingCode: String?
    var error: String?
}
