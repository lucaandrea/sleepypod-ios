import Foundation

protocol PersonalHistoryTransport: Sendable {
    func session() async throws -> HouseholdSession
    func page(_ query: PersonalHistoryQuery, cursor: String?) async throws -> PersonalHistoryPage
    func detail(_ id: UUID) async throws -> PersonalHistoryDetail
}
