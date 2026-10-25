import Foundation

struct MovementBucket: Decodable, Identifiable, Sendable {
    let side: String
    let bucketStart: String
    let totalMovement: Double
    let eventCount: Int
    let sampleCount: Int
    var id: String { side + ":" + bucketStart }
    var date: Date? { ReferenceDate.parse(bucketStart) }
    var eventsPerHour: Double { Double(eventCount) * 12 }
}

struct BiometricPresence: Decodable, Sendable {
    struct Movement: Decodable, Sendable { let active: Bool; let peakScore: Double }
    struct Level: Decodable, Sendable { let deviation: Double?; let ageMs: Double? }
    let occupied: Bool
    let available: Bool
    let classification: String
    let movement: Movement
    let level: Level
}

struct BiometricsLiveStatus: Sendable {
    let sides: [String: BiometricPresence]
    let credibility: [String: String]
    let latest: Date?
    let checked: Date
    func stalled(_ side: Side, now: Date) -> Bool {
        guard let presence = sides[side.rawValue], presence.available && presence.occupied,
              credibility[side.rawValue] == "occupied" else { return false }
        return latest.map { now.timeIntervalSince($0) > 15 * 60 } ?? true
    }
}
