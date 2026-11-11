import XCTest
@testable import Sleepypod

@MainActor final class BackupAlarmTests: XCTestCase {
    private func plan() throws -> NextAlarmState { try XCTUnwrap(NextAlarmExample.load().cases["scheduled"]) }
    private func fixture() -> (BackupAlarmCoordinator, BackupTestClient, BackupTestStorage) {
        let client = BackupTestClient(), storage = BackupTestStorage()
        let model = BackupAlarmCoordinator(client: client, owner: { storage.owner }, read: { storage.record },
            persist: { if storage.failWrite { throw BackupAlarmFailure.storage }; storage.record = $0 }, now: { storage.now })
        return (model, client, storage)
    }
    func testPolicyRejectsStaleFutureMissingAndUnavailablePlans() throws {
        let current = try plan()
        let before = try XCTUnwrap(NextAlarmState.instant(current.alarm!.at)).addingTimeInterval(-3600)
        XCTAssertNoThrow(try BackupAlarmPolicy.candidate(current, receivedAt: before, now: before))
        for receipt in [nil, before.addingTimeInterval(-91), before.addingTimeInterval(6)] {
            XCTAssertThrowsError(try BackupAlarmPolicy.candidate(current, receivedAt: receipt, now: before))
        }
        for name in ["skipped", "none", "away", "unknown", "acknowledged", "conflicting"] {
            let other = try XCTUnwrap(NextAlarmExample.load().cases[name])
            XCTAssertThrowsError(try BackupAlarmPolicy.candidate(other, receivedAt: before, now: before))
        }
        XCTAssertThrowsError(try BackupAlarmPolicy.candidate(current, receivedAt: before.addingTimeInterval(3590), now: before.addingTimeInterval(3590)))
    }
    func testPersistsBeforeSystemWriteAndReconcilesWithoutDuplicateSchedule() async throws {
        let (model, client, storage) = fixture(), current = try plan()
        storage.now = try XCTUnwrap(NextAlarmState.instant(current.alarm!.at)).addingTimeInterval(-3600)
        client.beforeSchedule = { id, _ in XCTAssertEqual(storage.record?.id, id) }
        await model.schedule(plan: current, receivedAt: storage.now, expectedOwner: storage.owner)
        XCTAssertEqual(model.systemState, "scheduled"); XCTAssertNotNil(model.checkedAt)
        await model.schedule(plan: current, receivedAt: storage.now, expectedOwner: storage.owner)
        XCTAssertEqual(client.schedules, 1); XCTAssertEqual(client.values.count, 1)
        XCTAssertEqual(model.record?.at, NextAlarmState.instant(current.alarm!.at))
    }
    func testUncertainAcceptedResultKeepsReceiptAndRefreshDiscoversIt() async throws {
        let (model, client, storage) = fixture(), current = try plan()
        storage.now = try XCTUnwrap(NextAlarmState.instant(current.alarm!.at)).addingTimeInterval(-3600)
        client.loseAcknowledgment = true
        await model.schedule(plan: current, receivedAt: storage.now, expectedOwner: storage.owner)
        XCTAssertNil(model.systemState); XCTAssertNotNil(storage.record); XCTAssertEqual(client.schedules, 1)
        model.refresh(); XCTAssertEqual(model.systemState, "scheduled"); XCTAssertNil(model.message)
        XCTAssertEqual(client.schedules, 1)
    }
    func testPermissionDenialAndFailedLocalWriteNeverSchedule() async throws {
        let (model, client, storage) = fixture(), current = try plan()
        storage.now = try XCTUnwrap(NextAlarmState.instant(current.alarm!.at)).addingTimeInterval(-3600)
        client.access = false; await model.schedule(plan: current, receivedAt: storage.now, expectedOwner: storage.owner)
        XCTAssertNil(storage.record); XCTAssertEqual(client.schedules, 0)
        client.access = true; storage.failWrite = true
        await model.schedule(plan: current, receivedAt: storage.now, expectedOwner: storage.owner)
        XCTAssertEqual(client.schedules, 0); XCTAssertNil(model.checkedAt)
    }
    func testPermissionDelayCannotUseExpiredOrChangedAccountRead() async throws {
        let (model, client, storage) = fixture(), current = try plan()
        storage.now = try XCTUnwrap(NextAlarmState.instant(current.alarm!.at)).addingTimeInterval(-3600)
        let received = storage.now
        client.onAccess = { storage.now = received.addingTimeInterval(91) }
        await model.schedule(plan: current, receivedAt: received, expectedOwner: storage.owner)
        XCTAssertEqual(client.schedules, 0)
        storage.now = received; client.onAccess = { storage.owner = String(repeating: "b", count: 64) }
        await model.schedule(plan: current, receivedAt: received, expectedOwner: storage.owner)
        XCTAssertEqual(client.schedules, 0); XCTAssertNil(storage.record)
    }
    func testReviewedConnectionMustStillMatchBeforeRequestingPermission() async throws {
        let (model, client, storage) = fixture(), current = try plan()
        storage.now = try XCTUnwrap(NextAlarmState.instant(current.alarm!.at)).addingTimeInterval(-3600)
        let reviewedOwner = storage.owner
        storage.owner = String(repeating: "b", count: 64)
        client.onAccess = { XCTFail("A changed connection must be rejected before asking for alarm access") }
        await model.schedule(plan: current, receivedAt: storage.now, expectedOwner: reviewedOwner)
        XCTAssertEqual(client.schedules, 0); XCTAssertNil(storage.record)
        XCTAssertEqual(model.message, BackupAlarmFailure.changed.localizedDescription)
        await model.schedule(plan: current, receivedAt: storage.now, expectedOwner: nil)
        XCTAssertEqual(client.schedules, 0)
    }
    func testOwnerChangeDuringSystemWriteRemovesOnlyTrackedBackup() async throws {
        let (model, client, storage) = fixture(), current = try plan()
        storage.now = try XCTUnwrap(NextAlarmState.instant(current.alarm!.at)).addingTimeInterval(-3600)
        let unrelated = BackupSystemAlarm(id: UUID(), at: storage.now.addingTimeInterval(7000), state: "scheduled")
        client.values = [unrelated]
        client.beforeSchedule = { _, _ in storage.owner = String(repeating: "b", count: 64) }
        await model.schedule(plan: current, receivedAt: storage.now, expectedOwner: storage.owner)
        XCTAssertNil(model.record); XCTAssertNil(storage.record)
        XCTAssertEqual(client.values, [unrelated]); XCTAssertEqual(client.cancels, 1)
    }
    func testOwnerChangeWithLostAcknowledgmentStillCancelsTrackedAlarm() async throws {
        let (model, client, storage) = fixture(), current = try plan()
        storage.now = try XCTUnwrap(NextAlarmState.instant(current.alarm!.at)).addingTimeInterval(-3600)
        client.beforeSchedule = { _, _ in storage.owner = nil }
        client.loseAcknowledgment = true
        await model.schedule(plan: current, receivedAt: storage.now, expectedOwner: storage.owner)
        XCTAssertNil(model.record); XCTAssertNil(storage.record)
        XCTAssertTrue(client.values.isEmpty); XCTAssertEqual(client.cancels, 1)
    }
    func testIdentityChangeCleanupAndCancellationFailurePreserveRecoverableID() async throws {
        let (model, client, storage) = fixture(), current = try plan()
        storage.now = try XCTUnwrap(NextAlarmState.instant(current.alarm!.at)).addingTimeInterval(-3600)
        await model.schedule(plan: current, receivedAt: storage.now, expectedOwner: storage.owner)
        let saved = storage.record
        storage.owner = nil; client.cancelFails = true; model.refresh()
        XCTAssertNil(model.record); XCTAssertEqual(storage.record, saved); XCTAssertNil(model.checkedAt)
        client.cancelFails = false; model.refresh()
        XCTAssertNil(storage.record); XCTAssertTrue(client.values.isEmpty)
    }
    func testCancelFailureCannotReplaceOrLoseTheOriginalBackup() async throws {
        let (model, client, storage) = fixture(), current = try plan()
        storage.now = try XCTUnwrap(NextAlarmState.instant(current.alarm!.at)).addingTimeInterval(-3600)
        await model.schedule(plan: current, receivedAt: storage.now, expectedOwner: storage.owner)
        let saved = storage.record; client.cancelFails = true
        let changed = try XCTUnwrap(NextAlarmExample.load().cases["changed"])
        await model.schedule(plan: changed, receivedAt: storage.now, expectedOwner: storage.owner)
        XCTAssertEqual(client.schedules, 1); XCTAssertEqual(storage.record, saved)
        model.cancel(); XCTAssertEqual(storage.record, saved)
        client.cancelFails = false; model.cancel(); XCTAssertNil(storage.record)
    }
    func testSystemDeletionAndUnknownScheduleNeverBecomeDeliveryClaimsOrRetries() async throws {
        let (model, client, storage) = fixture(), current = try plan()
        storage.now = try XCTUnwrap(NextAlarmState.instant(current.alarm!.at)).addingTimeInterval(-3600)
        await model.schedule(plan: current, receivedAt: storage.now, expectedOwner: storage.owner)
        client.values = []; model.refresh()
        XCTAssertEqual(model.systemState, "missing"); XCTAssertEqual(client.schedules, 1)
        let saved = try XCTUnwrap(storage.record)
        client.values = [.init(id: saved.id, at: saved.at.addingTimeInterval(60), state: "scheduled")]
        model.refresh(); XCTAssertEqual(model.systemState, "mismatch"); XCTAssertEqual(client.schedules, 1)
    }
}

@MainActor private final class BackupTestStorage {
    var record: BackupAlarmRecord?
    var owner: String? = String(repeating: "a", count: 64)
    var now = Date()
    var failWrite = false
}
@MainActor private final class BackupTestClient: BackupAlarmClient {
    var access = true
    var values: [BackupSystemAlarm] = []
    var schedules = 0
    var cancels = 0
    var loseAcknowledgment = false
    var cancelFails = false
    var onAccess: (() -> Void)?
    var beforeSchedule: ((UUID, Date) -> Void)?
    func requestAccess() async throws -> Bool { onAccess?(); return access }
    func alarms() throws -> [BackupSystemAlarm] { values }
    func schedule(id: UUID, at: Date) async throws {
        beforeSchedule?(id, at); schedules += 1
        values.append(.init(id: id, at: at, state: "scheduled"))
        if loseAcknowledgment { throw URLError(.cannotLoadFromNetwork) }
    }
    func cancel(id: UUID) throws {
        if cancelFails { throw BackupAlarmFailure.invalid }
        cancels += 1; values.removeAll { $0.id == id }
    }
}
