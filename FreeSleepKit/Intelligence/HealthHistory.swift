import Foundation

struct HealthHistory: Codable, Sendable, Equatable {
    struct Source: Codable, Identifiable, Sendable, Equatable {
        var id: String
        var name: String
        var nights: [Night]
    }
    struct Night: Codable, Identifiable, Sendable, Equatable {
        var id: String
        var start: Date
        var end: Date
        var asleepMinutes: Double
        var deepMinutes: Double?
        var remMinutes: Double?
        var restingHeartRate: Double?
        var hrv: Double?
        var respiratoryRate: Double?
    }
    var importedAt: Date
    var timeZone: String
    var sources: [Source]
    var ignoredSamples: Int
    static let empty = Self(importedAt: .distantPast, timeZone: TimeZone.current.identifier, sources: [], ignoredSamples: 0)
}

struct HistoricalSleepSample: Sendable {
    enum Stage: Sendable { case unspecified, core, deep, rem }
    var start: Date
    var end: Date
    var sourceID: String
    var sourceName: String
    var stage: Stage
}
