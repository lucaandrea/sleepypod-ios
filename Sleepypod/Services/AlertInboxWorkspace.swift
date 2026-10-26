import Foundation
import Observation

@MainActor @Observable final class AlertInboxWorkspace {
    let client: any AlertInboxServing
    private let now: () -> Date
    private(set) var latest: AlertPage?
    private(set) var receivedAt: Date?
    private(set) var items: [AutomationAlert] = []
    private(set) var nextBeforeId: Int64?
    private(set) var highWater: Int64?
    private var establishedBaseline = false
    private(set) var error: String?
    private(set) var acknowledgmentError: String?
    private(set) var notice: String?
    private(set) var busy = false
    private(set) var loadingOlder = false
    private(set) var pendingAcknowledgment: [Int64]?
    private(set) var announcements: [AutomationAlert] = []
    private(set) var announcementRevision = UUID()
    var selected = Set<Int64>()
    var isActive = false
    init(client: any AlertInboxServing, now: @escaping () -> Date = Date.init) { self.client = client; self.now = now }
    func serverTime(at date: Date) -> Double? {
        guard isActive, error == nil, let latest, let receivedAt else { return nil }
        let elapsed = date.timeIntervalSince(receivedAt)
        guard (0..<15).contains(elapsed) else { return nil }
        return Double(latest.generatedAt) + elapsed * 1000
    }
    func unreadCount(at date: Date) -> Int? {
        guard let time = serverTime(at: date), let latest, latest.delivery.foregroundInbox else { return nil }
        // The global count includes unread older pages; subtract only expiries actually observed here.
        let expired = latest.items.filter { $0.isUnread(at: Double(latest.generatedAt)) && !$0.isUnread(at: time) }.count
        return max(0, latest.unreadCount - expired)
    }
    func visibleAnnouncements(at date: Date) -> [AutomationAlert] {
        guard let time = serverTime(at: date) else { return [] }
        return announcements.filter { alert in items.first(where: { $0.id == alert.id })?.isUnread(at: time) == true }
    }
    func dismissAnnouncements() { announcements = [] }
    /// First read establishes a baseline. Rollbacks never lower this session's delivered-ID cursor.
    func refresh() async {
        guard !busy, !loadingOlder else { return }
        busy = true
        defer { busy = false }
        do {
            let page = try await client.page(before: nil); try page.validate(before: nil); try Task.checkCancellation()
            let oldCursor = highWater ?? 0
            let fresh = establishedBaseline && (page.newestId ?? 0) >= oldCursor && page.delivery.foregroundInbox
                ? page.items.filter { $0.id > oldCursor && $0.isUnread(at: Double(page.generatedAt)) } : []
            highWater = max(oldCursor, page.newestId ?? 0); establishedBaseline = true
            let retained = items.filter { item in
                !page.items.contains(where: { $0.id == item.id }) && item.id < (page.items.last?.id ?? 0)
                    && item.createdAt <= page.generatedAt && Double(page.generatedAt - item.createdAt) < 30 * 86_400_000
            }
            items = Array((page.items + retained).sorted { $0.id > $1.id }.prefix(1000))
            if latest == nil || retained.isEmpty { nextBeforeId = page.nextBeforeId }
            latest = page; receivedAt = now(); error = nil
            selected.formIntersection(Set(items.filter { $0.acknowledgedAt == nil }.map(\.id)))
            if let pending = pendingAcknowledgment, pending.allSatisfy({ identifier in items.contains { $0.id == identifier && $0.acknowledgedAt != nil } }) {
                pendingAcknowledgment = nil; acknowledgmentError = nil; notice = "Selected alerts confirmed read."
            }
            if !fresh.isEmpty { announcements = fresh; announcementRevision = UUID() }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription; announcements = [] } }
    }
    func loadOlder() async {
        guard !loadingOlder, !busy, let cursor = nextBeforeId else { return }
        loadingOlder = true; defer { loadingOlder = false }
        do {
            let page = try await client.page(before: cursor); try page.validate(before: cursor); try Task.checkCancellation()
            // History never moves the live cursor, updates its freshness, or announces alerts.
            var merged = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            for item in page.items { merged[item.id] = item }
            items = Array(merged.values.sorted { $0.id > $1.id }.prefix(1000)); nextBeforeId = page.nextBeforeId
            notice = nil
        } catch { if !Task.isCancelled { notice = "Older alerts could not be loaded. \(error.localizedDescription)" } }
    }
    func acknowledgeSelection() async {
        guard !busy, !loadingOlder, pendingAcknowledgment == nil, latest?.delivery.foregroundInbox == true,
              (1...50).contains(selected.count), selected.allSatisfy({ selectedId in items.contains { $0.id == selectedId && $0.acknowledgedAt == nil } }) else { return }
        pendingAcknowledgment = selected.sorted(); await retryAcknowledgment()
    }
    /// The endpoint is idempotent; retry exactly the reviewed IDs and never include later arrivals.
    func retryAcknowledgment() async {
        guard !busy, !loadingOlder, let identifiers = pendingAcknowledgment else { return }
        busy = true; acknowledgmentError = nil; defer { busy = false }
        do {
            let receipt = try await client.acknowledge(identifiers); try receipt.validate(requested: identifiers); try Task.checkCancellation()
            for index in items.indices where receipt.acknowledgedIds.contains(items[index].id) {
                if items[index].acknowledgedAt == nil { items[index].acknowledgedAt = receipt.generatedAt }
            }
            selected.subtract(identifiers); pendingAcknowledgment = nil
            notice = receipt.missingIds.isEmpty ? "Selected alerts marked read." : "\(receipt.acknowledgedIds.count) marked read; \(receipt.missingIds.count) no longer available."
            // The old global badge is no longer current. A later poll supplies the confirmed count.
            receivedAt = nil
        } catch { if !Task.isCancelled { acknowledgmentError = "Acknowledgment is unconfirmed. Retry the same \(identifiers.count) selected alerts or refresh. \(error.localizedDescription)" } }
    }
}
