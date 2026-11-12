import Foundation

struct PersonalReportEvidence: Equatable {
    let identity: PersonalHealthIdentity
    let healthRevision: UUID
    let sourceID: String
    let sourceName: String
    let importedAt: Date
    let facts: [SleepFact]
    let comparison: ReportSleepComparison?
}
