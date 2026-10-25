import Foundation

struct PersonalSleepReport: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var createdAt: Date
    var provider: IntelligenceProvider
    var model: String
    var source: String
    var facts: [SleepFact]
    var text: String
    var inputTokens: Int?
    var outputTokens: Int?
}

struct PersonalIntelligenceArchive: Codable, Sendable {
    var history: HealthHistory = .empty
    var reports: [PersonalSleepReport] = []
}
