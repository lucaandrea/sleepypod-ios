import XCTest
@testable import Sleepypod

@MainActor final class LaterWakeTests: XCTestCase {
    func testCoreGeneratedPreviewPreservesNullsTimesAndTheCompleteApplyPacket() throws {
        for name in ["ordinary", "movement-window", "pod-timezone"] {
            let fixture = try LaterWakeTestFixture(name)
            let packet = try fixture.packet()
            XCTAssertNoThrow(try packet.preview.validateSaved(fixture.saved))
            XCTAssertEqual(packet.preview.proposed.duration, 20)
            XCTAssertEqual(packet.preview.proposed.targetF, 105)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: packet.application(now: fixture.now)) as? [String: Any])
            let echoed = try XCTUnwrap(payload["preview"] as? NSDictionary)
            XCTAssertEqual(echoed, try JSONSerialization.jsonObject(with: fixture.previewData) as? NSDictionary)
            let before = try XCTUnwrap(echoed["before"] as? [String: Any])
            XCTAssertTrue(before["execution"] is NSNull)
            XCTAssertTrue(before["change"] is NSNull)
        }
    }
    func testMalformedOrChangedPreviewEvidenceCannotBeDisplayedOrApplied() throws {
        let fixture = try LaterWakeTestFixture()
        let patches: [([String: Any]) -> [String: Any]] = [
            { $0.merging(["effect": "applied"]) { _, value in value } },
            { $0.merging(["weeklyScheduleChanged": true]) { _, value in value } },
            { $0.merging(["externalDevices": "all"]) { _, value in value } },
            { $0.merging(["expiresAt": "2026-10-26T05:02:00.000Z"]) { _, value in value } },
            { fields in var fields = fields; var proposal = fields["proposed"] as! [String: Any]; proposal["targetF"] = 80; fields["proposed"] = proposal; return fields },
            { fields in var fields = fields; var proposal = fields["proposed"] as! [String: Any]; proposal["warmingStartsAt"] = "2026-10-26T08:40:00.000Z"; fields["proposed"] = proposal; return fields },
            { fields in var fields = fields; var request = fields["request"] as! [String: Any]; request["time"] = "10:00"; fields["request"] = request; return fields }
        ]
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.previewData) as? [String: Any])
        for patch in patches {
            let data = try JSONSerialization.data(withJSONObject: patch(source))
            XCTAssertThrowsError(try LaterWakePacket(data: data, input: fixture.input, now: fixture.now))
        }
        let packet = try fixture.packet()
        XCTAssertThrowsError(try packet.application(now: fixture.now.addingTimeInterval(90)))
        XCTAssertThrowsError(try packet.application(now: fixture.now.addingTimeInterval(-1)))
        XCTAssertThrowsError(try packet.preview.validateSaved(fixture.before))
    }
    func testPreviewIsReadOnlyAndAcceptedSaveKeepsPendingTimersDistinct() async throws {
        let fixture = try LaterWakeTestFixture(), client = LaterWakeTestClient(fixture: fixture)
        let model = NextAlarmWorkspace(now: { fixture.now })
        model.configure(client: client, side: .left); await model.load(); model.beginLater(); model.editLaterTime("09:00")
        await model.previewLater()
        XCTAssertTrue(model.canApplyLater); let observedResult1 = await client.count(); XCTAssertEqual(observedResult1, 0)
        let observedResult2 = await model.skip(); XCTAssertFalse(observedResult2); let observedResult3 = await model.restore(); XCTAssertFalse(observedResult3)
        let saved = await model.applyLater()
        XCTAssertEqual(saved?.alarm?.at, fixture.saved.alarm?.at); XCTAssertNil(model.laterDraft)
        XCTAssertTrue(model.notice?.contains("Timer registration is pending") == true)
        let observedResult4 = await client.count(); XCTAssertEqual(observedResult4, 1)
        let observedResult5 = await model.applyLater(); XCTAssertNil(observedResult5)
    }
    func testTimeEditExpiryAndBackgroundingWithdrawThePreview() async throws {
        let fixture = try LaterWakeTestFixture(), clock = LaterWakeTestClock()
        clock.now = fixture.now
        let client = LaterWakeTestClient(fixture: fixture), model = NextAlarmWorkspace(now: { clock.now })
        model.configure(client: client, side: .left); await model.load(); model.beginLater(); model.editLaterTime("09:00")
        await model.previewLater(); XCTAssertTrue(model.canApplyLater)
        model.editLaterTime("10:00"); XCTAssertNil(model.laterDraft?.packet)
        model.editLaterTime("09:00"); await model.previewLater()
        clock.now.addTimeInterval(90); XCTAssertTrue(model.laterExpired); XCTAssertFalse(model.canApplyLater)
        let observedResult6 = await model.applyLater(); XCTAssertNil(observedResult6); let observedResult7 = await client.count(); XCTAssertEqual(observedResult7, 0)
        model.invalidate(); XCTAssertNil(model.laterDraft?.packet); XCTAssertEqual(model.laterDraft?.time, "09:00")
        XCTAssertFalse(model.laterChanged, "Missing data is not evidence of a concurrent edit")
    }
    func testLostSaveRequiresExplicitReadAndDoesNotReplayOrRebaseTheDraft() async throws {
        let fixture = try LaterWakeTestFixture(), client = LaterWakeTestClient(fixture: fixture, loseReply: true)
        let model = NextAlarmWorkspace(now: { fixture.now })
        model.configure(client: client, side: .left); await model.load(); model.beginLater(); model.editLaterTime("09:00")
        await model.previewLater(); let observedResult8 = await model.applyLater(); XCTAssertNil(observedResult8)
        XCTAssertTrue(model.requiresReload); XCTAssertEqual(model.laterDraft?.time, "09:00")
        let observedResult9 = await model.applyLater(); XCTAssertNil(observedResult9); await model.load(); XCTAssertTrue(model.requiresReload)
        await model.load(userInitiated: true)
        XCTAssertTrue(model.laterChanged); XCTAssertNil(model.error); XCTAssertFalse(model.canPreviewLater)
        let observedResult10 = await client.count(); XCTAssertEqual(observedResult10, 1)
    }
    func testCompanionSavesPodBeforePhoneAndReportsPermissionFailureSeparately() async throws {
        for access in [true, false] {
            let fixture = try LaterWakeTestFixture(), client = LaterWakeTestClient(fixture: fixture)
            let phone = BackupTestClient(), storage = BackupTestStorage(); storage.now = fixture.now; phone.access = access
            let backup = BackupAlarmCoordinator(client: phone, owner: { storage.owner }, read: { storage.record }, persist: { storage.record = $0 }, now: { storage.now })
            let companion = LaterWakeCompanion(backup: backup, owner: { storage.owner })
            let model = NextAlarmWorkspace(now: { fixture.now })
            model.configure(client: client, side: .left); await model.load(); model.beginLater(); model.editLaterTime("09:00")
            companion.setPhone(true); await companion.preview(model)
            XCTAssertEqual(companion.review?.phone, .absent); XCTAssertEqual(phone.schedules, 0)
            phone.beforeSchedule = { _, _ in XCTAssertEqual(model.current?.revision, fixture.saved.revision) }
            await companion.apply(model)
            XCTAssertEqual(companion.outcome?.plan, fixture.saved)
            XCTAssertEqual(companion.outcome?.phone, access ? .confirmed : .unconfirmed)
            XCTAssertEqual(phone.schedules, access ? 1 : 0)
            await companion.apply(model)
            let writes = await client.count(); XCTAssertEqual(writes, 1)
        }
    }
    func testReviewedExistingBackupIsReplacedOnceAndOptionChangesRequireANewReview() async throws {
        let fixture = try LaterWakeTestFixture(), client = LaterWakeTestClient(fixture: fixture)
        let phone = BackupTestClient(), storage = BackupTestStorage(); storage.now = fixture.now
        let backup = BackupAlarmCoordinator(client: phone, owner: { storage.owner }, read: { storage.record }, persist: { storage.record = $0 }, now: { storage.now })
        await backup.schedule(plan: fixture.before, receivedAt: fixture.now, expectedOwner: storage.owner)
        let original = try XCTUnwrap(storage.record)
        let companion = LaterWakeCompanion(backup: backup, owner: { storage.owner }), model = NextAlarmWorkspace(now: { fixture.now })
        model.configure(client: client, side: .left); await model.load(); model.beginLater(); model.editLaterTime("09:00")
        companion.setPhone(true); await companion.preview(model)
        XCTAssertEqual(companion.review?.phone, .existing(original)); XCTAssertTrue(companion.canApply(model))
        companion.setPhone(false); XCTAssertFalse(companion.canApply(model))
        companion.setPhone(true); XCTAssertFalse(companion.canApply(model))
        await companion.preview(model); await companion.apply(model)
        XCTAssertEqual(companion.outcome?.phone, .confirmed); XCTAssertEqual(phone.cancels, 1); XCTAssertEqual(phone.schedules, 2)
        XCTAssertNotEqual(storage.record?.id, original.id); XCTAssertEqual(storage.record?.at, fixture.saved.alarm.flatMap { NextAlarmState.instant($0.at) })
    }
    func testPodOnlySaveNeverRequestsPhonePermissionOrChangesItsAlarm() async throws {
        let fixture = try LaterWakeTestFixture(), client = LaterWakeTestClient(fixture: fixture)
        let phone = BackupTestClient(), storage = BackupTestStorage(); storage.now = fixture.now
        phone.onAccess = { XCTFail("Pod-only save cannot request phone alarm permission") }
        let backup = BackupAlarmCoordinator(client: phone, owner: { storage.owner }, read: { storage.record }, persist: { storage.record = $0 }, now: { storage.now })
        let companion = LaterWakeCompanion(backup: backup, owner: { storage.owner }), model = NextAlarmWorkspace(now: { fixture.now })
        model.configure(client: client, side: .left); await model.load(); model.beginLater(); model.editLaterTime("09:00")
        await companion.preview(model); await companion.apply(model)
        XCTAssertEqual(companion.outcome?.phone, .unchanged); XCTAssertEqual(phone.schedules, 0); XCTAssertEqual(phone.cancels, 0)
    }
    func testSyntheticLaterPreviewMovesSourceTimingWithoutLiveServices() async throws {
        let client = SyntheticLaterWakeClient(scenario: "later-normal")
        let before = try await client.read(side: .right)
        let input = try LaterWakeRequest(base: before, time: "08:00"), packet = try await client.previewLater(input)
        XCTAssertEqual(packet.preview.proposed.targetF, 105); XCTAssertEqual(packet.preview.proposed.duration, 20)
        XCTAssertEqual(packet.preview.before.side, .right)
        let saved = try await client.applyLater(packet)
        XCTAssertNoThrow(try packet.preview.validateSaved(saved))
        let restored = try await client.write(NextAlarmWrite(base: saved, action: "restore"))
        XCTAssertEqual(restored.alarm?.time, "07:00")
    }
    func testLostPodReplyNeverChangesThePhoneAndReadbackDoesNotReplay() async throws {
        let fixture = try LaterWakeTestFixture(), client = LaterWakeTestClient(fixture: fixture, loseReply: true)
        let phone = BackupTestClient(), storage = BackupTestStorage(); storage.now = fixture.now
        let backup = BackupAlarmCoordinator(client: phone, owner: { storage.owner }, read: { storage.record }, persist: { storage.record = $0 }, now: { storage.now })
        let companion = LaterWakeCompanion(backup: backup, owner: { storage.owner }), model = NextAlarmWorkspace(now: { fixture.now })
        model.configure(client: client, side: .left); await model.load(); model.beginLater(); model.editLaterTime("09:00")
        companion.setPhone(true); await companion.preview(model); await companion.apply(model)
        XCTAssertNil(companion.outcome); XCTAssertEqual(phone.schedules, 0); XCTAssertTrue(model.requiresReload)
        await model.load(userInitiated: true); await companion.apply(model)
        XCTAssertEqual(phone.schedules, 0); let writes = await client.count(); XCTAssertEqual(writes, 1)
    }
    func testChangingReviewedPhoneBeforePodSaveStopsBothRequests() async throws {
        let fixture = try LaterWakeTestFixture(), client = LaterWakeTestClient(fixture: fixture)
        let phone = BackupTestClient(), storage = BackupTestStorage(); storage.now = fixture.now
        let backup = BackupAlarmCoordinator(client: phone, owner: { storage.owner }, read: { storage.record }, persist: { storage.record = $0 }, now: { storage.now })
        let companion = LaterWakeCompanion(backup: backup, owner: { storage.owner }), model = NextAlarmWorkspace(now: { fixture.now })
        model.configure(client: client, side: .left); await model.load(); model.beginLater(); model.editLaterTime("09:00")
        companion.setPhone(true); await companion.preview(model)
        await backup.schedule(plan: fixture.before, receivedAt: fixture.now, expectedOwner: storage.owner)
        await companion.apply(model)
        let writes = await client.count(); XCTAssertEqual(writes, 0); XCTAssertEqual(phone.schedules, 1); XCTAssertEqual(phone.cancels, 0)
        XCTAssertNotNil(companion.error); XCTAssertNil(companion.review)
    }
    func testPhoneChangeDuringPodSaveProducesPartialResultWithoutReplacingIt() async throws {
        let fixture = try LaterWakeTestFixture(), client = LaterWakeTestClient(fixture: fixture)
        let phone = BackupTestClient(), storage = BackupTestStorage(); storage.now = fixture.now
        let backup = BackupAlarmCoordinator(client: phone, owner: { storage.owner }, read: { storage.record }, persist: { storage.record = $0 }, now: { storage.now })
        let companion = LaterWakeCompanion(backup: backup, owner: { storage.owner }), model = NextAlarmWorkspace(now: { fixture.now })
        model.configure(client: client, side: .left); await model.load(); model.beginLater(); model.editLaterTime("09:00")
        companion.setPhone(true); await companion.preview(model); await client.hold()
        let operation = Task { await companion.apply(model) }; await client.waitUntilHeld()
        await backup.schedule(plan: fixture.before, receivedAt: fixture.now, expectedOwner: storage.owner)
        let reviewed = storage.record
        await client.release(); await operation.value
        XCTAssertEqual(companion.outcome?.phone, .unconfirmed); XCTAssertEqual(model.current, fixture.saved)
        XCTAssertEqual(storage.record, reviewed); XCTAssertEqual(phone.schedules, 1); XCTAssertEqual(phone.cancels, 0)
    }
    func testLeavingCompanionDuringPodSaveWithdrawsResultAndDoesNotSchedulePhone() async throws {
        let fixture = try LaterWakeTestFixture(), client = LaterWakeTestClient(fixture: fixture)
        let phone = BackupTestClient(), storage = BackupTestStorage(); storage.now = fixture.now
        let backup = BackupAlarmCoordinator(client: phone, owner: { storage.owner }, read: { storage.record }, persist: { storage.record = $0 }, now: { storage.now })
        let companion = LaterWakeCompanion(backup: backup, owner: { storage.owner }), model = NextAlarmWorkspace(now: { fixture.now })
        model.configure(client: client, side: .left); await model.load(); model.beginLater(); model.editLaterTime("09:00")
        companion.setPhone(true); await companion.preview(model); await client.hold()
        let operation = Task { await companion.apply(model) }; await client.waitUntilHeld()
        companion.invalidate(); model.invalidate(); await client.release(); await operation.value
        XCTAssertNil(companion.outcome); XCTAssertEqual(phone.schedules, 0); XCTAssertTrue(model.requiresReload)
    }
    func testPhoneResultReconcilesRemovalMissingMismatchStalenessAndOwnerChanges() async throws {
        for state in ["removed", "missing", "mismatch", "stale", "owner"] {
            let fixture = try LaterWakeTestFixture(), client = LaterWakeTestClient(fixture: fixture)
            let phone = BackupTestClient(), storage = BackupTestStorage(); storage.now = fixture.now
            let backup = BackupAlarmCoordinator(client: phone, owner: { storage.owner }, read: { storage.record }, persist: { storage.record = $0 }, now: { storage.now })
            let companion = LaterWakeCompanion(backup: backup, owner: { storage.owner }), model = NextAlarmWorkspace(now: { fixture.now })
            model.configure(client: client, side: .left); await model.load(); model.beginLater(); model.editLaterTime("09:00")
            companion.setPhone(true); await companion.preview(model); await companion.apply(model)
            XCTAssertEqual(companion.reconciledOutcome(now: storage.now)?.phone, .confirmed)
            switch state {
            case "removed": backup.cancel()
            case "missing": phone.values = []; backup.refresh()
            case "mismatch":
                let original = try XCTUnwrap(phone.values.first)
                phone.values = [.init(id: original.id, at: try XCTUnwrap(original.at).addingTimeInterval(60), state: "scheduled")]; backup.refresh()
            case "stale": storage.now.addTimeInterval(61)
            default: storage.owner = String(repeating: "b", count: 64)
            }
            let result = try XCTUnwrap(companion.reconciledOutcome(now: storage.now))
            XCTAssertEqual(result.phone, .unconfirmed, state); XCTAssertEqual(result.plan, fixture.saved)
            XCTAssertFalse(result.phoneMessage?.contains("iOS confirms") == true)
            XCTAssertEqual(phone.schedules, 1, "Reconciliation never recreates an alarm")
        }
    }
    func testClosingReviewWithdrawsReceiptButPreservesTrackedBackupForReconciliation() async throws {
        let fixture = try LaterWakeTestFixture(), client = LaterWakeTestClient(fixture: fixture)
        let phone = BackupTestClient(), storage = BackupTestStorage(); storage.now = fixture.now
        let backup = BackupAlarmCoordinator(client: phone, owner: { storage.owner }, read: { storage.record }, persist: { storage.record = $0 }, now: { storage.now })
        let companion = LaterWakeCompanion(backup: backup, owner: { storage.owner }), model = NextAlarmWorkspace(now: { fixture.now })
        model.configure(client: client, side: .left); await model.load(); model.beginLater(); model.editLaterTime("09:00")
        companion.setPhone(true); await companion.preview(model); await companion.apply(model)
        let saved = try XCTUnwrap(storage.record)
        companion.invalidate(); model.invalidate(); await model.load(); backup.refresh()
        XCTAssertNil(companion.outcome); XCTAssertEqual(backup.record, saved); XCTAssertEqual(backup.systemState, "scheduled")
        XCTAssertEqual(model.current?.change, fixture.saved.change)
        XCTAssertEqual(phone.schedules, 1); XCTAssertEqual(phone.cancels, 0)
    }
    func testLateReplyAfterLeavingCannotPublishOrEnableAnotherSave() async throws {
        let fixture = try LaterWakeTestFixture(), client = LaterWakeTestClient(fixture: fixture)
        let model = NextAlarmWorkspace(now: { fixture.now })
        model.configure(client: client, side: .left); await model.load(); model.beginLater(); model.editLaterTime("09:00")
        await model.previewLater(); await client.hold()
        let operation = Task { await model.applyLater() }; await client.waitUntilHeld()
        model.invalidate(); await client.release()
        let observedResult11 = await operation.value; XCTAssertNil(observedResult11); XCTAssertNil(model.current); XCTAssertTrue(model.requiresReload)
        await model.load(userInitiated: true); XCTAssertTrue(model.laterChanged)
        let observedResult12 = await client.count(); XCTAssertEqual(observedResult12, 1)
    }
}

struct LaterWakeTestFixture: Sendable {
    let now: Date
    let before: NextAlarmState
    let saved: NextAlarmState
    let input: LaterWakeRequest
    let previewData: Data
    init(_ name: String = "ordinary") throws {
        let path = try XCTUnwrap(Bundle.main.url(forResource: "later-wake-example", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        now = try XCTUnwrap((root["now"] as? String).flatMap(NextAlarmState.instant))
        let cases = try XCTUnwrap(root["cases"] as? [String: [String: Any]]), values = try XCTUnwrap(cases[name])
        before = try JSONDecoder().decode(NextAlarmState.self, from: JSONSerialization.data(withJSONObject: values["before"] as Any))
        saved = try JSONDecoder().decode(NextAlarmState.self, from: JSONSerialization.data(withJSONObject: values["saved"] as Any))
        input = try LaterWakeRequest(base: before, time: "09:00")
        previewData = try JSONSerialization.data(withJSONObject: values["preview"] as Any)
    }
    func packet() throws -> LaterWakePacket { try .init(data: previewData, input: input, now: now) }
}
private actor LaterWakeTestClient: LaterWakeClient {
    let fixture: LaterWakeTestFixture
    let loseReply: Bool
    private var changed = false
    private var writes = 0
    private var holding = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(fixture: LaterWakeTestFixture, loseReply: Bool = false) { self.fixture = fixture; self.loseReply = loseReply }
    func available() async throws {}
    func laterAvailable() async throws {}
    func read(side: Side) async throws -> NextAlarmState { changed ? fixture.saved : fixture.before }
    func write(_ input: NextAlarmWrite) async throws -> NextAlarmState { throw NextAlarmFailure.invalid }
    func previewLater(_ input: LaterWakeRequest) async throws -> LaterWakePacket { try fixture.packet() }
    func applyLater(_ packet: LaterWakePacket) async throws -> NextAlarmState {
        writes += 1
        if holding { holding = false; await withCheckedContinuation { continuation = $0 } }
        changed = true
        if loseReply { throw URLError(.networkConnectionLost) }
        return fixture.saved
    }
    func count() -> Int { writes }
    func hold() { holding = true }
    func waitUntilHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor private final class LaterWakeTestClock { var now = Date() }
