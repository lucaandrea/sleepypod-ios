import XCTest
@testable import Sleepypod

@MainActor final class BedtimeRoutineTests: XCTestCase {
    private func routine() -> BedtimeRoutineDraft {
        var draft = BedtimeRoutineDraft.blank; draft.power.enabled = true
        draft.temperatures = [.init(time: "02:00", temperature: 70, enabled: true), .init(time: "23:00", temperature: 72, enabled: true)]
        draft.alarm = .standard; return draft
    }
    private func input(_ draft: BedtimeRoutineDraft, day: DayOfWeek = .monday, revision: String? = nil) -> BedtimeRoutineChanges {
        .init(side: .left, changes: [.init(dayOfWeek: day, expectedRevision: revision, replacement: draft)])
    }
    func testCoreEncodingIncludesNullAlarmRevisionAndDeletion() throws {
        let data = try JSONEncoder().encode(input(.blank))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let change = (root["changes"] as! [[String: Any]])[0], draft = change["replacement"] as! [String: Any]
        XCTAssertTrue(change["expectedRevision"] is NSNull); XCTAssertTrue(draft["alarm"] is NSNull)
        let deletion = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BedtimeRoutineChange(dayOfWeek: .monday, expectedRevision: String(repeating: "a", count: 64), replacement: nil))) as! [String: Any]
        XCTAssertTrue(deletion["replacement"] is NSNull)
    }
    func testNormalizationPreservesCustomSnoozeAndUsesNightChronology() throws {
        var draft = routine(); draft.notes = "  Read first  "; draft.alarm?.snoozeDuration = 420; draft.alarm?.snoozeTaper = 40
        let normalized = draft.normalized
        XCTAssertEqual(normalized.temperatures.map(\.time), ["23:00", "02:00"]); XCTAssertEqual(normalized.notes, "Read first")
        XCTAssertEqual(normalized.alarm?.snoozeDuration, 420); XCTAssertEqual(normalized.alarm?.snoozeTaper, 40)
        draft.alarm?.snoozeDuration = nil; draft.alarm?.snoozeTaper = nil
        XCTAssertEqual(draft.normalized.alarm?.snoozeDuration, 300); XCTAssertEqual(draft.normalized.alarm?.snoozeTaper, 0)
        XCTAssertEqual(BedtimeRoutineTime.eventDay(.saturday, time: "02:00", start: "22:00"), .sunday)
        XCTAssertEqual(BedtimeRoutineTime.eventDay(.monday, time: "22:00", start: "22:00"), .monday)
    }
    func testValidationMatchesCorePhaseAlarmAndUTF16Boundaries() throws {
        var draft = routine(); XCTAssertNoThrow(try draft.validate())
        draft.alarm?.time = "12:00"; XCTAssertNoThrow(try draft.validate(), "Core permits an alarm outside the thermal window")
        draft.temperatures[0].time = "07:00"; XCTAssertThrowsError(try draft.validate())
        draft.temperatures[0].enabled = false; XCTAssertNoThrow(try draft.validate())
        draft.temperatures[0].time = "23:00"; XCTAssertThrowsError(try draft.validate(), "Paused phases still need distinct times")
        draft = routine(); draft.power.offTime = draft.power.onTime; XCTAssertThrowsError(try draft.validate())
        draft = routine(); draft.alarm?.duration = 9; XCTAssertThrowsError(try draft.validate())
        draft = routine(); draft.notes = String(repeating: "😀", count: 501); XCTAssertThrowsError(try draft.validate())
        XCTAssertNil(BedtimeRoutineTime.minutes("24:00")); XCTAssertNil(BedtimeRoutineTime.minutes("7:00"))
    }
    func testWeeklySeamOverlapAndDuplicateMorningPowerEvents() throws {
        let saturday = routine()
        var sunday = BedtimeRoutineDraft.blank; sunday.power.enabled = true; sunday.power.onTime = "06:30"; sunday.power.offTime = "08:00"
        XCTAssertThrowsError(try BedtimeRoutineTime.validateWeek([(.saturday, saturday), (.sunday, sunday)]))
        sunday.power.onTime = "07:00"
        XCTAssertThrowsError(try BedtimeRoutineTime.validateWeek([(.saturday, saturday), (.sunday, sunday)]), "Adjacent windows can still have a duplicate power event")
        sunday.power.onTime = "07:01"; XCTAssertNoThrow(try BedtimeRoutineTime.validateWeek([(.saturday, saturday), (.sunday, sunday)]))
        sunday.power.enabled = false; sunday.power.onTime = "06:30"; XCTAssertNoThrow(try BedtimeRoutineTime.validateWeek([(.saturday, saturday), (.sunday, sunday)]))
    }
    func testDemoAtomicConflictDoesNotPartiallyCopyOrCrossSides() async throws {
        let client = DemoBedtimeRoutineClient(); _ = try await client.replace(input(routine()))
        let before = await client.routines(side: .left)
        let changes = BedtimeRoutineChanges(side: .left, changes: [
            .init(dayOfWeek: .tuesday, expectedRevision: nil, replacement: routine()),
            .init(dayOfWeek: .monday, expectedRevision: nil, replacement: .blank)
        ])
        do { _ = try await client.replace(changes); XCTFail("Stale revision accepted") } catch { }
        let after = await client.routines(side: .left), right = await client.routines(side: .right)
        XCTAssertEqual(after.routines, before.routines); XCTAssertTrue(right.routines.isEmpty)
        _ = try await client.replace(.init(side: .left, changes: [.init(dayOfWeek: .monday, expectedRevision: before.routines[0].revision, replacement: nil)]))
        let deleted = await client.routines(side: .left); XCTAssertTrue(deleted.routines.isEmpty)
    }
    func testUnmanagedCalendarSchedulesPreventRoutineReplacement() async throws {
        let client = DemoBedtimeRoutineClient(canCreate: false)
        do { _ = try await client.replace(input(routine())); XCTFail("Unmanaged calendar rows overwritten") } catch { }
        let book = await client.routines(side: .left); XCTAssertTrue(book.routines.isEmpty)
    }
    func testLostSaveResponseRequiresReloadWithoutReplaying() async throws {
        let client = RoutineTestClient(), model = BedtimeRoutineWorkspace(); model.configure(client: client, side: .left); await model.load()
        await client.setLostResponse()
        let first = await model.save(input(routine())), second = await model.save(input(routine()))
        let writes = await client.writes
        XCTAssertFalse(first); XCTAssertFalse(second); XCTAssertEqual(writes, 1); XCTAssertTrue(model.requiresReload); XCTAssertNil(model.book)
        await model.load(); XCTAssertFalse(model.requiresReload); XCTAssertEqual(model.book?.routines.count, 1)
    }
    func testUnacknowledgedSchedulerIsReportedAsSavedWithoutExtraWrite() async throws {
        let client = RoutineTestClient(), model = BedtimeRoutineWorkspace(); model.configure(client: client, side: .left); await model.load()
        await client.setSchedulerUnacknowledged()
        let result = await model.save(input(routine())), writes = await client.writes
        XCTAssertTrue(result); XCTAssertEqual(writes, 1); XCTAssertEqual(model.book?.routines.count, 1)
        XCTAssertTrue(model.notice?.contains("has not confirmed") == true)
    }
    func testChangedTargetAndOwnerInvalidationPreventUnsentWrites() async throws {
        let client = RoutineTestClient(), model = BedtimeRoutineWorkspace(); model.configure(client: client, side: .left); await model.load()
        _ = try await client.replace(input(routine()))
        let conflict = await model.save(input(.blank)); XCTAssertFalse(conflict)
        let conflictWrites = await client.writes; XCTAssertEqual(conflictWrites, 1)
        await model.load(); let current = try XCTUnwrap(model.book?.routines.first)
        await client.holdRead()
        let pending = Task { await model.save(input(.blank, revision: current.revision)) }
        await client.waitForRead(); model.invalidate(); await client.releaseRead()
        let result = await pending.value, writes = await client.writes
        XCTAssertFalse(result); XCTAssertEqual(writes, 1); XCTAssertNil(model.book)
    }
}
private actor RoutineTestClient: BedtimeRoutineClient {
    let demo = DemoBedtimeRoutineClient()
    private(set) var writes = 0
    private var lostResponse = false, schedulerApplied = true, hold = false
    private var continuation: CheckedContinuation<Void, Never>?, observer: CheckedContinuation<Void, Never>?
    func setLostResponse() { lostResponse = true }
    func setSchedulerUnacknowledged() { schedulerApplied = false }
    func holdRead() { hold = true }
    func waitForRead() async { if continuation == nil { await withCheckedContinuation { observer = $0 } } }
    func releaseRead() { continuation?.resume(); continuation = nil }
    func routines(side: Side) async -> BedtimeRoutineBook {
        if hold { hold = false; await withCheckedContinuation { continuation = $0; observer?.resume(); observer = nil } }
        return await demo.routines(side: side)
    }
    func replace(_ input: BedtimeRoutineChanges) async throws -> BedtimeRoutineReceipt {
        writes += 1; let receipt = try await demo.replace(input)
        if lostResponse { throw URLError(.timedOut) }
        return .init(version: receipt.version, side: receipt.side, canCreate: receipt.canCreate, routines: receipt.routines, schedulerApplied: schedulerApplied)
    }
}
