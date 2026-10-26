import XCTest
@testable import Sleepypod

@MainActor final class HomeRoomContextTests: XCTestCase {
    private func fixture() throws -> HomeRoomCoreFixture { try .load() }
    private func workspace(_ client: RoomMemoryClient, clock: RoomTestClock = .init()) -> HomeRoomWorkspace {
        let model = HomeRoomWorkspace(client: client, now: { clock.date }); model.isActive = true; return model
    }
    func testCoreGeneratedFixtureAndMappingValidation() throws {
        let fixture = try fixture(); try fixture.status.validate(); try fixture.history.validate(before: nil)
        XCTAssertEqual(fixture.publishers.automations.count, 3)
        let publisher = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture.publishers.automations[0].utf8)) as? [String: Any])
        let actions = try XCTUnwrap(publisher["actions"] as? [[String: Any]])
        let data = try XCTUnwrap(actions[0]["data"] as? [String: Any])
        XCTAssertEqual(data["retain"] as? Bool, false); XCTAssertTrue((data["payload"] as? String)?.contains("state_attr('sensor.example_temperature', 'measured_at')") == true)
        var config = fixture.status.config; config.mappings[0].unit = "ppm"
        XCTAssertThrowsError(try config.validated())
        config = .empty; config.enabled = true; XCTAssertThrowsError(try config.validated())
        config = fixture.status.config; config.mappings[0].timestampAttribute = "now()"; XCTAssertThrowsError(try config.validated())
        config = fixture.status.config; config.mappings[0].maxAgeSeconds = 901; XCTAssertThrowsError(try config.validated())
        config = fixture.status.config; config.mappings.append(config.mappings[0]); XCTAssertThrowsError(try config.validated())
        config = .empty; config.roomName = String(repeating: "😀", count: 31); XCTAssertThrowsError(try config.validated())
    }
    func testSourceExpiryUsesServerTimeAndFailedOrStaleReadWithholdsImmediately() async throws {
        let fixture = try fixture(); let clock = RoomTestClock(); let client = RoomMemoryClient(fixture)
        let model = workspace(client, clock: clock); await model.refresh()
        let observation = try XCTUnwrap(model.status?.observations.first)
        XCTAssertEqual(model.value(observation, at: clock.date), 71.6)
        clock.date.addTimeInterval(15); XCTAssertNil(model.value(observation, at: clock.date))
        await model.refresh(); await client.failStatus(); await model.refresh()
        XCTAssertNil(model.value(observation, at: clock.date)); XCTAssertNotNil(model.status)
        await client.recover(); await model.refresh(); model.isActive = false
        XCTAssertNil(model.value(observation, at: clock.date)); model.isActive = true
        clock.date.addTimeInterval(-1); XCTAssertNil(model.freshServerTime(at: clock.date))
    }
    func testMeasurementExpiresBetweenSuccessfulPolls() async throws {
        let fixture = try fixture(); var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.status)) as? [String: Any])
        var rows = try XCTUnwrap(payload["observations"] as? [[String: Any]])
        rows[0]["measuredAt"] = fixture.status.generatedAt - 119_000; rows[0]["expiresAt"] = fixture.status.generatedAt + 1_000
        payload["observations"] = rows
        let status = try JSONDecoder().decode(HomeRoomStatus.self, from: JSONSerialization.data(withJSONObject: payload))
        let client = RoomMemoryClient(fixture); await client.set(status)
        let clock = RoomTestClock(); let model = workspace(client, clock: clock); await model.refresh()
        let item = try XCTUnwrap(model.status?.observations.first); XCTAssertNotNil(model.value(item, at: clock.date))
        clock.date.addTimeInterval(2); XCTAssertNil(model.value(item, at: clock.date)); XCTAssertNotNil(model.freshServerTime(at: clock.date))
    }
    func testLostSaveReadbackConfirmsExactMappingWithoutAnotherWrite() async throws {
        let client = RoomMemoryClient(try fixture()); let model = workspace(client)
        await model.refresh(); model.draft.roomName = "Example new name"
        let review = try model.reviewedSave(); await client.dropReply(apply: true); await model.save(review)
        XCTAssertNotNil(model.pending); XCTAssertNil(model.receivedAt)
        await model.refresh(); XCTAssertNil(model.pending); XCTAssertEqual(model.base?.revision, 8)
        XCTAssertEqual(model.draft.roomName, "Example new name"); XCTAssertFalse(model.hasDraft)
        let calls = await client.counts(); XCTAssertEqual(calls.saves, [7]); XCTAssertEqual(calls.publishers, 0)
    }
    func testUnobservedSavePreservesDraftForExplicitReview() async throws {
        let client = RoomMemoryClient(try fixture()); let model = workspace(client)
        await model.refresh(); model.draft.roomName = "Preserved draft"
        await client.dropReply(apply: false); await model.save(try model.reviewedSave()); await model.refresh()
        XCTAssertNil(model.pending); XCTAssertEqual(model.base?.revision, 7); XCTAssertTrue(model.hasDraft)
        XCTAssertEqual(model.draft.roomName, "Preserved draft"); XCTAssertTrue(model.canSave)
        let calls = await client.counts(); XCTAssertEqual(calls.saves, [7])
    }
    func testSuccessfulSaveWithdrawsOldStatusWithoutClaimingAConflict() async throws {
        let client = RoomMemoryClient(try fixture()); let model = workspace(client)
        await model.refresh(); model.draft.roomName = "Saved name"
        await model.save(try model.reviewedSave())
        XCTAssertEqual(model.base?.revision, 8); XCTAssertNil(model.receivedAt)
        XCTAssertFalse(model.conflict); XCTAssertFalse(model.canSave)
        await model.refresh(); XCTAssertFalse(model.conflict); XCTAssertEqual(model.status?.revision, 8)
    }
    func testRemoteRevisionPreservesDirtyDraftAndRequiresExplicitReload() async throws {
        let fixture = try fixture(); let client = RoomMemoryClient(fixture); let model = workspace(client)
        await model.refresh(); model.draft.roomName = "My draft"
        var config = fixture.status.config; config.roomName = "Another client"
        await client.set(roomStatus(fixture.status, version: .init(revision: 8, config: config)))
        await model.refresh(); XCTAssertEqual(model.draft.roomName, "My draft"); XCTAssertTrue(model.conflict); XCTAssertFalse(model.canSave)
        model.reloadDraft(); XCTAssertEqual(model.draft.roomName, "Another client"); XCTAssertFalse(model.conflict)
        let calls = await client.counts(); XCTAssertTrue(calls.saves.isEmpty)
    }
    func testReviewCannotBeAppliedToAnotherOwnerWithIdenticalConfiguration() async throws {
        let fixture = try fixture(); let firstClient = RoomMemoryClient(fixture); let secondClient = RoomMemoryClient(fixture)
        let first = workspace(firstClient); let second = workspace(secondClient)
        await first.refresh(); await second.refresh()
        let reviewed = try first.reviewedSave(); await second.save(reviewed)
        let calls = await secondClient.counts(); XCTAssertTrue(calls.saves.isEmpty)
    }
    func testPublisherIsBoundToFreshCurrentRevisionAndWithdrawnAfterChange() async throws {
        let fixture = try fixture(); let clock = RoomTestClock(); let client = RoomMemoryClient(fixture); let model = workspace(client, clock: clock)
        await model.refresh(); await model.loadPublishers(); XCTAssertTrue(model.canUsePublisher(at: clock.date))
        clock.date.addTimeInterval(15); XCTAssertFalse(model.canUsePublisher(at: clock.date))
        await client.set(roomStatus(fixture.status, version: .init(revision: 8, config: fixture.status.config)))
        await model.refresh(); XCTAssertNil(model.publisher)
        await model.loadPublishers(); XCTAssertNil(model.publisher); XCTAssertNotNil(model.publisherError)
    }
    func testHistoryPaginationAndExportContainOnlyLoadedHistoricalRows() async throws {
        let fixture = try fixture(); let client = RoomMemoryClient(fixture); let model = workspace(client)
        await client.setHistory(.init(apiVersion: 1, generatedAt: fixture.history.generatedAt, items: Array(fixture.history.items.prefix(2)), nextBeforeId: 9))
        await model.loadHistory(); XCTAssertEqual(model.history.count, 2)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(model.historyJSON().utf8)) as? [String: Any])
        XCTAssertEqual((first["items"] as? [[String: Any]])?.count, 2)
        await client.setHistory(.init(apiVersion: 1, generatedAt: fixture.history.generatedAt, items: Array(fixture.history.items.suffix(1)), nextBeforeId: nil))
        await model.loadHistory(older: true); XCTAssertEqual(model.history.map(\.id), [10, 9, 8]); XCTAssertNil(model.nextHistory)
        let calls = await client.counts(); XCTAssertEqual(calls.history, [nil, 9]); XCTAssertTrue(calls.saves.isEmpty)
    }
}

@MainActor private final class RoomTestClock { var date = Date(timeIntervalSince1970: 2_000_000_000) }
private func roomStatus(_ original: HomeRoomStatus, version: HomeRoomVersion) -> HomeRoomStatus {
    .init(apiVersion: 1, generatedAt: original.generatedAt, revision: version.revision, config: version.config, connected: original.connected, topic: original.topic,
          observations: version.config.mappings.map { .init(metric: $0.metric, entityId: $0.entityId, unit: $0.metric.unit, value: nil, lastValue: nil,
                                                           measuredAt: nil, reportedAt: nil, receivedAt: nil, expiresAt: nil, status: version.config.enabled ? .waiting : .disabled) })
}
private actor RoomMemoryClient: HomeRoomServing {
    private var value: HomeRoomStatus
    private var historyValue: HomeRoomHistory
    private let documents: HomeRoomPublishers
    private var failed = false
    private var drop = false
    private var applyDropped = true
    private var saves: [Int64] = []
    private var publisherCalls = 0
    private var historyCalls: [Int64?] = []
    init(_ fixture: HomeRoomCoreFixture) { value = fixture.status; historyValue = fixture.history; documents = fixture.publishers }
    func set(_ value: HomeRoomStatus) { self.value = value }
    func setHistory(_ value: HomeRoomHistory) { historyValue = value }
    func failStatus() { failed = true }
    func recover() { failed = false }
    func dropReply(apply: Bool) { drop = true; applyDropped = apply }
    func counts() -> (saves: [Int64], publishers: Int, history: [Int64?]) { (saves, publisherCalls, historyCalls) }
    func status() throws -> HomeRoomStatus { if failed { throw HomeRoomStatus.issue("Synthetic offline") }; return value }
    func configure(_ config: HomeRoomConfiguration, expectedRevision: Int64) throws -> HomeRoomVersion {
        saves.append(expectedRevision)
        guard expectedRevision == value.revision else { throw HomeRoomStatus.issue("Synthetic conflict") }
        let result = HomeRoomVersion(revision: value.revision + 1, config: config)
        if !drop || applyDropped { value = roomStatus(value, version: result) }
        if drop { throw HomeRoomStatus.issue("Synthetic lost reply") }; return result
    }
    func history(before: Int64?) -> HomeRoomHistory { historyCalls.append(before); return historyValue }
    func publishers() -> HomeRoomPublishers { publisherCalls += 1; return documents }
}
