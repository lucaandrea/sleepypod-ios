import XCTest
@testable import Sleepypod

@MainActor final class AlertInboxTests: XCTestCase {
    func testMatchesCoreGeneratedForegroundCursorFixture() async throws {
        struct Fixture: Decodable {
            struct Step: Decodable {
                struct Expected: Decodable { let cursor: Int64?; let items: [AutomationAlert] }
                let page: AlertPage; let expected: Expected
            }
            let steps: [Step]
        }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "alert-inbox-core", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let client = AlertMemoryClient(); let model = AlertInboxWorkspace(client: client); model.isActive = true
        for step in fixture.steps {
            model.dismissAnnouncements(); await client.set(step.page); await model.refresh()
            XCTAssertEqual(model.highWater, step.expected.cursor)
            XCTAssertEqual(model.announcements.map(\.id), step.expected.items.map(\.id))
        }
    }
    func testInitialBaselineNewDeliveryAndRollbackNeverReplay() async throws {
        let client = AlertMemoryClient(); let model = AlertInboxWorkspace(client: client); model.isActive = true
        await client.set(.page([2, 1])); await model.refresh()
        XCTAssertTrue(model.announcements.isEmpty); XCTAssertEqual(model.highWater, 2)
        await client.set(.page([3, 2])); await model.refresh()
        XCTAssertEqual(model.announcements.map(\.id), [3]); model.dismissAnnouncements()
        await client.set(.page([1])); await model.refresh(); XCTAssertEqual(model.highWater, 3)
        await client.set(.page([3, 2, 1])); await model.refresh(); XCTAssertTrue(model.announcements.isEmpty)
        let counts = await client.counts(); XCTAssertEqual(counts.acknowledgments, [])
    }
    func testServerClockExpiryStalenessFailureAndBackgroundWithholdBadge() async throws {
        let clock = AlertTestClock(); let client = AlertMemoryClient()
        let model = AlertInboxWorkspace(client: client, now: { clock.date }); model.isActive = true
        await client.set(.page([1], generated: 100_000, lifetime: 2_000)); await model.refresh()
        XCTAssertEqual(model.unreadCount(at: clock.date), 1)
        clock.date.addTimeInterval(3); XCTAssertEqual(model.unreadCount(at: clock.date), 0)
        clock.date.addTimeInterval(13); XCTAssertNil(model.unreadCount(at: clock.date))
        await model.refresh(); model.isActive = false; XCTAssertNil(model.unreadCount(at: clock.date))
        model.isActive = true; await client.fail(); await model.refresh()
        XCTAssertEqual(model.items.count, 1); XCTAssertNil(model.unreadCount(at: clock.date)); XCTAssertNotNil(model.error)
        clock.date.addTimeInterval(-30); XCTAssertNil(model.serverTime(at: clock.date))
    }
    func testOlderPagesDoNotAnnounceOrRefreshLiveCount() async throws {
        let clock = AlertTestClock(); let client = AlertMemoryClient()
        let model = AlertInboxWorkspace(client: client, now: { clock.date }); model.isActive = true
        await client.set(.page([4, 3], next: 3)); await model.refresh()
        let received = model.receivedAt
        await client.set(.page([2, 1], newest: 4)); await model.loadOlder()
        XCTAssertEqual(model.items.map(\.id), [4, 3, 2, 1]); XCTAssertNil(model.nextBeforeId)
        XCTAssertEqual(model.receivedAt, received); XCTAssertTrue(model.announcements.isEmpty)
        let calls = await client.counts(); XCTAssertEqual(calls.pages, [nil, 3])
    }
    func testLostAcknowledgmentRetriesFrozenSelectionOnly() async throws {
        let client = AlertMemoryClient(); let model = AlertInboxWorkspace(client: client); model.isActive = true
        await client.set(.page([2, 1])); await model.refresh(); model.selected = [2]
        await client.loseAcknowledgment(); await model.acknowledgeSelection()
        XCTAssertEqual(model.pendingAcknowledgment, [2]); XCTAssertNil(model.items[0].acknowledgedAt)
        await client.set(.page([3, 2, 1])); await model.refresh(); model.selected = [3]
        await model.retryAcknowledgment()
        let calls = await client.counts(); XCTAssertEqual(calls.acknowledgments, [[2], [2]])
        XCTAssertNil(model.items.first { $0.id == 3 }?.acknowledgedAt)
        XCTAssertNotNil(model.items.first { $0.id == 2 }?.acknowledgedAt)
        XCTAssertNil(model.pendingAcknowledgment); XCTAssertNil(model.unreadCount(at: .now))
    }
    func testRefreshCanConfirmUnknownAcknowledgmentWithoutSecondMutation() async throws {
        let client = AlertMemoryClient(); let model = AlertInboxWorkspace(client: client)
        await client.set(.page([2])); await model.refresh(); model.selected = [2]
        await client.loseAcknowledgment(); await model.acknowledgeSelection()
        await client.set(.page([2], acknowledged: [2])); await model.refresh()
        XCTAssertNil(model.pendingAcknowledgment); XCTAssertNil(model.acknowledgmentError)
        let calls = await client.counts(); XCTAssertEqual(calls.acknowledgments, [[2]])
    }
    func testMalformedAcknowledgmentCannotMarkAnythingRead() async throws {
        let client = AlertMemoryClient(); let model = AlertInboxWorkspace(client: client)
        await client.set(.page([2, 1])); await model.refresh(); model.selected = [2]
        await client.malformedAcknowledgment(); await model.acknowledgeSelection()
        XCTAssertEqual(model.pendingAcknowledgment, [2]); XCTAssertTrue(model.items.allSatisfy { $0.acknowledgedAt == nil })
    }
    func testOwnerChangeDiscardsInboxAndRejectsLateDisplayFromOldSession() async throws {
        let session = AlertInboxSession(); let delayed = DelayedAlertClient()
        session.configure(scope: "owner-one", client: delayed)
        let old = try XCTUnwrap(session.workspace)
        let task = Task { await old.refresh() }
        await delayed.waitUntilRequested()
        session.configure(scope: "owner-two", client: DemoAlertInboxClient())
        let current = try XCTUnwrap(session.workspace)
        await current.refresh(); await delayed.complete(.page([9])); await task.value
        XCTAssertFalse(current === old); XCTAssertEqual(old.items.count, 1)
        XCTAssertTrue(session.workspace?.items.isEmpty == true); XCTAssertEqual(session.workspace?.highWater, 0)
    }
    func testContractRejectsOversizedDuplicateUnorderedAndInvalidCursorPages() throws {
        try AlertPage.page([2, 1]).validate(before: nil)
        XCTAssertThrowsError(try AlertPage.page([1, 1]).validate(before: nil))
        XCTAssertThrowsError(try AlertPage.page([1, 2]).validate(before: nil))
        XCTAssertThrowsError(try AlertPage.page(Array((1...51).reversed()).map(Int64.init)).validate(before: nil))
        XCTAssertThrowsError(try AlertPage.page([2, 1], next: 3).validate(before: nil))
        XCTAssertThrowsError(try AlertPage.page([2, 1]).validate(before: 2))
        XCTAssertThrowsError(try AlertAcknowledgment(generatedAt: 100, acknowledgedIds: [2], missingIds: [2]).validate(requested: [2]))
    }
}

@MainActor private final class AlertTestClock { var date = Date(timeIntervalSince1970: 2_000_000_000) }
private extension AlertPage {
    static func page(_ identifiers: [Int64], generated: Int64 = 100_000, lifetime: Int64 = 900_000,
                     newest: Int64? = nil, next: Int64? = nil, acknowledged: Set<Int64> = []) -> Self {
        .init(apiVersion: 1, generatedAt: generated, newestId: newest ?? identifiers.max(), nextBeforeId: next,
              unreadCount: identifiers.filter { !acknowledged.contains($0) }.count,
              items: identifiers.map { .init(id: $0, source: "automation", sourceId: 1, title: "Synthetic", message: "Literal <message> only", createdAt: generated - 1_000,
                                               expiresAt: generated + lifetime, acknowledgedAt: acknowledged.contains($0) ? generated : nil) },
              delivery: .init(foregroundInbox: true, backgroundPush: false))
    }
}
private actor AlertMemoryClient: AlertInboxServing {
    private var value = AlertPage.page([])
    private var failed = false
    private var lose = false
    private var malformed = false
    private var pages: [Int64?] = []
    private var acknowledgments: [[Int64]] = []
    func set(_ value: AlertPage) { self.value = value; failed = false }
    func fail() { failed = true }
    func loseAcknowledgment() { lose = true }
    func malformedAcknowledgment() { malformed = true }
    func counts() -> (pages: [Int64?], acknowledgments: [[Int64]]) { (pages, acknowledgments) }
    func page(before: Int64?) throws -> AlertPage {
        pages.append(before)
        if failed { throw APIError.serverError(message: "Synthetic offline") }; return value
    }
    func acknowledge(_ identifiers: [Int64]) throws -> AlertAcknowledgment {
        acknowledgments.append(identifiers)
        if lose { lose = false; throw APIError.serverError(message: "Synthetic lost response") }
        return .init(generatedAt: 100_001, acknowledgedIds: malformed ? [99] : identifiers, missingIds: [])
    }
}
private actor DelayedAlertClient: AlertInboxServing {
    private var continuation: CheckedContinuation<AlertPage, Never>?
    func page(before: Int64?) async -> AlertPage { await withCheckedContinuation { continuation = $0 } }
    func waitUntilRequested() async { while continuation == nil { await Task.yield() } }
    func complete(_ value: AlertPage) { continuation?.resume(returning: value); continuation = nil }
    func acknowledge(_ identifiers: [Int64]) throws -> AlertAcknowledgment { throw AlertPage.invalid }
}
