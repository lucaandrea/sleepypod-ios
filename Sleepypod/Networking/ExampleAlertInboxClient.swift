import Foundation

/// Separate, explicitly opened example. The ordinary Demo inbox remains empty and unavailable.
actor ExampleAlertInboxClient: AlertInboxServing {
    private var read = Set<Int64>()
    private let reference = Int64(Date.now.timeIntervalSince1970 * 1000)
    func page(before: Int64?) -> AlertPage {
        let values: [Int64] = before == nil ? [3, 2] : [1]
        return .init(apiVersion: 1, generatedAt: Int64(Date.now.timeIntervalSince1970 * 1000), newestId: 3,
                     nextBeforeId: before == nil ? 2 : nil, unreadCount: [Int64(3), 2].filter { !read.contains($0) }.count,
                     items: values.map { identifier in
            .init(id: identifier, source: "automation", sourceId: 1, title: identifier == 3 ? "Example room reminder" : "Example evening reminder",
                  message: identifier == 3 ? "Synthetic message: check your bedroom conditions before settling in." : "Synthetic message: your evening routine is approaching.",
                  createdAt: reference - (identifier == 1 ? 1_000_000 : 30_000),
                  expiresAt: reference + (identifier == 1 ? -100_000 : 870_000), acknowledgedAt: read.contains(identifier) ? reference : nil)
        }, delivery: .init(foregroundInbox: true, backgroundPush: false))
    }
    func acknowledge(_ identifiers: [Int64]) -> AlertAcknowledgment {
        read.formUnion(identifiers)
        return .init(generatedAt: Int64(Date.now.timeIntervalSince1970 * 1000), acknowledgedIds: identifiers.filter { (1...3).contains($0) }, missingIds: identifiers.filter { !(1...3).contains($0) })
    }
}
