import Foundation

struct OfflineReading<Value: Codable & Sendable>: Codable, Sendable {
    let savedAt: Date
    let value: Value
}

struct OfflineLibrary: Codable, Sendable {
    var version = 1
    var timeZone = "America/Los_Angeles"
    var schedules: OfflineReading<Schedules>?
    var left: OfflineReading<[SleepRecord]>?
    var right: OfflineReading<[SleepRecord]>?

    func records(for side: Side) -> OfflineReading<[SleepRecord]>? { side == .left ? left : right }
}
