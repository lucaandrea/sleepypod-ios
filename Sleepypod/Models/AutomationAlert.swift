import Foundation

struct AutomationAlert: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let source: String
    let sourceId: Int64
    let title: String
    let message: String
    let createdAt: Int64
    let expiresAt: Int64
    var acknowledgedAt: Int64?
    func isUnread(at time: Double) -> Bool { acknowledgedAt == nil && Double(createdAt) <= time && time < Double(expiresAt) }
    func validate() throws {
        guard AlertPage.valid(id), AlertPage.valid(sourceId), source == "automation",
              (1...200).contains(title.utf16.count), (1...2000).contains(message.utf16.count),
              AlertPage.valid(createdAt), AlertPage.valid(expiresAt), expiresAt > createdAt,
              acknowledgedAt.map(AlertPage.valid) ?? true else { throw AlertPage.invalid }
    }
}
struct AlertPage: Codable, Sendable {
    struct Delivery: Codable, Sendable { let foregroundInbox: Bool; let backgroundPush: Bool }
    let apiVersion: Int
    let generatedAt: Int64
    let newestId: Int64?
    let nextBeforeId: Int64?
    let unreadCount: Int
    let items: [AutomationAlert]
    let delivery: Delivery
    static let maximumInteger: Int64 = 9_007_199_254_740_991
    static var invalid: APIError { .serverError(message: "The controller returned an incompatible alert response.") }
    static func valid(_ value: Int64) -> Bool { value > 0 && value <= maximumInteger }
    func validate(before: Int64?) throws {
        guard apiVersion == 1, Self.valid(generatedAt), !delivery.backgroundPush, unreadCount >= 0,
              items.count <= 50, newestId.map(Self.valid) ?? true, nextBeforeId.map(Self.valid) ?? true,
              Set(items.map(\.id)).count == items.count,
              items.map(\.id) == items.map(\.id).sorted(by: >),
              items.allSatisfy({ $0.id <= (newestId ?? 0) && $0.createdAt <= generatedAt && (before == nil || $0.id < before!) }),
              nextBeforeId == nil || nextBeforeId == items.last?.id,
              nextBeforeId == nil || before == nil || nextBeforeId! < before! else { throw Self.invalid }
        for item in items { try item.validate() }
    }
}
struct AlertAcknowledgment: Decodable, Sendable {
    let generatedAt: Int64
    let acknowledgedIds: [Int64]
    let missingIds: [Int64]
    func validate(requested: [Int64]) throws {
        let returned = acknowledgedIds + missingIds
        guard AlertPage.valid(generatedAt), returned.allSatisfy(AlertPage.valid),
              Set(returned).count == returned.count, Set(returned) == Set(requested) else { throw AlertPage.invalid }
    }
}
