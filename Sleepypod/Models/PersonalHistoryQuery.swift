import Foundation

struct PersonalHistoryQuery: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case presence, vitals, movement
        var title: String {
            switch self {
            case .presence: "In bed"
            case .vitals: "Vitals"
            case .movement: "Movement"
            }
        }
    }
    let startsAt: Int64
    let endsAt: Int64
    let kind: Kind
    let limit: Int

    static func validTime(_ value: Int64) -> Bool { (0...8_640_000_000_000_000).contains(value) }
    func validate() throws {
        guard Self.validTime(startsAt), Self.validTime(endsAt), endsAt > startsAt,
              endsAt - startsAt <= 90 * 86_400_000, (1...100).contains(limit) else { throw HouseholdFailure.invalid }
    }
    func overlaps(_ record: PersonalHistoryRecord) -> Bool { record.startsAt < endsAt && record.endsAt > startsAt }
}
