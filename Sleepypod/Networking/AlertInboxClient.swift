import Foundation

protocol AlertInboxServing: Sendable {
    func page(before: Int64?) async throws -> AlertPage
    func acknowledge(_ identifiers: [Int64]) async throws -> AlertAcknowledgment
}
struct CoreAlertInboxClient: AlertInboxServing {
    let transport: CoreRESTClient
    func page(before: Int64?) async throws -> AlertPage {
        let page: AlertPage = try await transport.get("v1/notifications", query: before.map { ["beforeId": String($0)] } ?? [:])
        try page.validate(before: before); return page
    }
    func acknowledge(_ identifiers: [Int64]) async throws -> AlertAcknowledgment {
        guard (1...50).contains(identifiers.count), Set(identifiers).count == identifiers.count,
              identifiers.allSatisfy(AlertPage.valid) else { throw AlertPage.invalid }
        struct Request: Encodable, Sendable { let ids: [Int64] }
        let receipt: AlertAcknowledgment = try await transport.post("v1/notifications/acknowledge", body: Request(ids: identifiers), returning: AlertAcknowledgment.self)
        try receipt.validate(requested: identifiers); return receipt
    }
}
struct DemoAlertInboxClient: AlertInboxServing {
    func page(before: Int64?) -> AlertPage {
        .init(apiVersion: 1, generatedAt: Int64(Date.now.timeIntervalSince1970 * 1000), newestId: nil, nextBeforeId: nil,
              unreadCount: 0, items: [], delivery: .init(foregroundInbox: false, backgroundPush: false))
    }
    func acknowledge(_ identifiers: [Int64]) throws -> AlertAcknowledgment {
        throw APIError.serverError(message: "Live alerts are unavailable in Demo.")
    }
}
