import Foundation

/// Calculated, reviewable evidence crosses the module boundary; raw records and credentials do not.
public struct NativeSleepFact: Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}

public struct NativePodEvidence: Sendable, Equatable {
    public let side: String
    public let days: Int
    public let timeZone: String
    public let start: Date
    public let end: Date
    public let facts: [NativeSleepFact]
    public let summary: String
    public let hasObservations: Bool
    public init(side: String, days: Int, timeZone: String, start: Date, end: Date,
                facts: [NativeSleepFact], summary: String, hasObservations: Bool) {
        self.side = side; self.days = days; self.timeZone = timeZone; self.start = start; self.end = end
        self.facts = facts; self.summary = summary; self.hasObservations = hasObservations
    }
}
