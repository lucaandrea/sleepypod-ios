import Foundation

struct PersonalHistoryDetail: Codable, Equatable, Sendable {
    let version: Int
    let scope: PersonalHistoryScope
    let attributionRevision: Int
    let generatedAt: Int64
    let source: String
    let interpretation: String
    let record: PersonalHistoryRecord

    static func decodeExact(_ data: Data) throws -> Self {
        try PersonalHistoryDecoding.check(data, detail: true)
        return try JSONDecoder().decode(Self.self, from: data)
    }
    func validate(for session: HouseholdSession) throws {
        try PersonalHistoryDecoding.envelope(version: version, attribution: attributionRevision, generatedAt: generatedAt, source: source, interpretation: interpretation)
        try scope.validate(for: session); try record.validate(sleeperId: scope.sleeperId)
    }
}
