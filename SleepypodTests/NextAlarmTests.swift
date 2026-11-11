import XCTest
@testable import Sleepypod

@MainActor final class NextAlarmTests: XCTestCase {
    private func example(_ name: String) throws -> NextAlarmState { try XCTUnwrap(NextAlarmExample.load().cases[name]) }
    func testSourceGeneratedStatesPreserveSkippedFollowingAndExecutionEvidence() throws {
        let fixture = try NextAlarmExample.load(); XCTAssertTrue(fixture.synthetic); XCTAssertEqual(fixture.cases.count, 12)
        for value in fixture.cases.values { try value.validate(side: .left) }
        let skipped = try example("skipped")
        XCTAssertEqual(skipped.state, "skipped"); XCTAssertEqual(skipped.alarm?.at, "2026-10-26T07:00:00.000Z")
        XCTAssertEqual(skipped.followingAt, "2026-11-02T07:00:00.000Z")
        XCTAssertNil(skipped.change?.at); XCTAssertEqual(try example("changed").alarm?.originalAt, skipped.alarm?.originalAt)
        for name in ["attempting", "unknown", "acknowledged"] {
            let value = try example(name); XCTAssertFalse(value.canChange); XCTAssertEqual(value.execution, name)
            XCTAssertEqual(value.acknowledgment, "accepted_not_physically_verified")
        }
        XCTAssertEqual(try example("expired").change?.status, "expired"); XCTAssertEqual(try example("invalidated").change?.status, "invalidated")
    }
    func testInconsistentOccurrenceAndExecutionAuthorityAreRejected() throws {
        let scheduled = try example("scheduled")
        let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scheduled)) as! [String: Any]
        for patch in [["state": "none"], ["execution": "unknown"]] {
            let fields = original.merging(patch) { _, value in value }
            let value = try JSONDecoder().decode(NextAlarmState.self, from: JSONSerialization.data(withJSONObject: fields))
            XCTAssertThrowsError(try value.validate(side: .left))
        }
    }
    func testOptionalWarmingMetadataRejectsWrongOrderTemperatureAndState() throws {
        var value = try example("scheduled")
        XCTAssertNotNil(value.warming, "The fixture must exercise Core's canonical warm-up response")
        // Missing optional metadata from older controllers remains readable.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        legacy.removeValue(forKey: "warming")
        let oldController = try JSONDecoder().decode(NextAlarmState.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(oldController.warming)
        XCTAssertNoThrow(try oldController.validate(side: .left))
        value.warming = .init(startsAt: "2026-10-26T06:30:00Z", endsAt: "2026-10-26T07:16:00Z", earliestVibrationAt: "2026-10-26T07:00:00Z", targetF: try XCTUnwrap(value.alarm?.alarmTemperatureF))
        XCTAssertNoThrow(try value.validate(side: .left))
        var attempted = try example("unknown"); attempted.warming = value.warming
        XCTAssertThrowsError(try attempted.validate(side: .left))
        value.warming = .init(startsAt: "2026-10-26T07:30:00Z", endsAt: "2026-10-26T07:16:00Z", earliestVibrationAt: "2026-10-26T07:00:00Z", targetF: try XCTUnwrap(value.alarm?.alarmTemperatureF))
        XCTAssertThrowsError(try value.validate(side: .left))
        var skipped = try example("skipped"); skipped.warming = value.warming
        XCTAssertThrowsError(try skipped.validate(side: .left))
        value.warming = .init(startsAt: "2026-10-26T06:30:00Z", endsAt: "2026-10-26T07:16:00Z", earliestVibrationAt: "2026-10-26T07:00:00Z", targetF: 200)
        XCTAssertThrowsError(try value.validate(side: .left))
    }
    func testSyntheticTimeChangePreservesCanonicalWarmupIntervals() async throws {
        let client = SyntheticNextAlarmClient(scenario: "scheduled")
        let before = try await client.read(side: .left)
        let changed = try await client.write(NextAlarmWrite(base: before, action: "time", time: "09:15"))
        try changed.validate(side: .left)
        let source = try example("changed")
        let sourceWarmup = try XCTUnwrap(source.warming), changedWarmup = try XCTUnwrap(changed.warming)
        let sourceAt = try XCTUnwrap(source.alarm.flatMap { NextAlarmState.instant($0.at) })
        let changedAt = try XCTUnwrap(changed.alarm.flatMap { NextAlarmState.instant($0.at) })
        for (original, updated) in [(sourceWarmup.startsAt, changedWarmup.startsAt), (sourceWarmup.endsAt, changedWarmup.endsAt), (sourceWarmup.earliestVibrationAt, changedWarmup.earliestVibrationAt)] {
            XCTAssertEqual(try XCTUnwrap(NextAlarmState.instant(original)).timeIntervalSince(sourceAt),
                           try XCTUnwrap(NextAlarmState.instant(updated)).timeIntervalSince(changedAt))
        }
        XCTAssertEqual(changed.alarm?.time, "09:15")
    }
    func testWritesPreserveExactRevisionAndTimestampStringsWithOnlyActionFields() throws {
        let base = try example("scheduled"), skipped = try example("skipped")
        let requests = [try NextAlarmWrite(base: base, action: "skip"), try NextAlarmWrite(base: base, action: "time", time: "08:00"), try NextAlarmWrite(base: skipped, action: "restore")]
        for request in requests {
            let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
            let expected: Set<String> = request.action == "restore" ? ["side", "action", "expectedRevision", "expectedExpiresAt"]
                : request.action == "time" ? ["side", "action", "expectedRevision", "expectedAt", "time"] : ["side", "action", "expectedRevision", "expectedAt"]
            XCTAssertEqual(Set(fields.keys), expected)
            XCTAssertEqual(fields["expectedRevision"] as? String, request.action == "restore" ? skipped.revision : base.revision)
            XCTAssertEqual(fields[request.action == "restore" ? "expectedExpiresAt" : "expectedAt"] as? String, request.action == "restore" ? skipped.change?.expiresAt : base.alarm?.at)
        }
        XCTAssertThrowsError(try NextAlarmWrite(base: base, action: "time", time: "24:00"))
        XCTAssertThrowsError(try NextAlarmWrite(base: example("conflicting"), action: "skip"))
        XCTAssertThrowsError(try NextAlarmWrite(base: base, action: "restore"))
    }
    func testLostSaveRequiresExplicitReadAndKeepsOriginalTimeDraftUntilReview() async throws {
        let client = NextAlarmTestClient(scenario: "lost-save"), model = NextAlarmWorkspace()
        model.configure(client: client, side: .left); await model.load(); model.beginTime(); model.editTime("08:00")
        let original = model.draft?.base.revision
        let saved = await model.saveTime(); XCTAssertFalse(saved); XCTAssertTrue(model.requiresReload)
        let retry = await model.saveTime(); XCTAssertFalse(retry); await model.load(); XCTAssertTrue(model.requiresReload)
        await model.load(userInitiated: true)
        XCTAssertEqual(model.draft?.time, "08:00"); XCTAssertEqual(model.draft?.base.revision, original)
        XCTAssertTrue(model.changedDraft); XCTAssertFalse(model.canSaveDraft)
        let count = await client.writeCount; XCTAssertEqual(count, 1)
        model.cancelTime(); model.beginTime(); XCTAssertFalse(model.changedDraft); XCTAssertTrue(model.canSaveDraft)
    }
    func testConflictAndFailedReadKeepDraftWithoutRebasingOrRetrying() async throws {
        let client = NextAlarmTestClient(scenario: "conflict"), model = NextAlarmWorkspace()
        model.configure(client: client, side: .left); await model.load(); model.beginTime(); model.editTime("08:00")
        _ = await model.saveTime(); await client.failRead(); await model.load(userInitiated: true)
        XCTAssertNil(model.current); XCTAssertEqual(model.draft?.time, "08:00"); XCTAssertTrue(model.requiresReload)
        await model.load(userInitiated: true); XCTAssertTrue(model.changedDraft); XCTAssertFalse(model.canSaveDraft)
        let count = await client.writeCount; XCTAssertEqual(count, 1)
    }
    func testSkipRestoreAndPendingTimersStayDistinctFromPhysicalDelivery() async throws {
        let model = NextAlarmWorkspace(); model.configure(client: SyntheticNextAlarmClient(scenario: "pending"), side: .left); await model.load()
        let skipped = await model.skip(); XCTAssertTrue(skipped); XCTAssertEqual(model.current?.state, "skipped")
        XCTAssertTrue(model.notice?.contains("Timer registration is pending") == true)
        let restored = await model.restore(); XCTAssertTrue(restored); XCTAssertEqual(model.current?.state, "scheduled"); XCTAssertNil(model.current?.change)
    }
    func testInterruptedWriteAndConnectionChangeCannotPublishOrUnlockRetry() async throws {
        let client = NextAlarmTestClient(scenario: "scheduled"), model = NextAlarmWorkspace()
        model.configure(client: client, side: .left); await model.load(); await client.hold()
        let operation = Task { await model.skip() }; await client.waitUntilHeld(); model.invalidate(); await client.release()
        let result = await operation.value; XCTAssertFalse(result); XCTAssertNil(model.current); XCTAssertTrue(model.requiresReload)
        await model.load(); XCTAssertNil(model.current); await model.load(userInitiated: true); XCTAssertEqual(model.current?.state, "skipped")
        await client.hold(); let restoring = Task { await model.restore() }; await client.waitUntilHeld()
        model.configure(client: SyntheticNextAlarmClient(scenario: "none"), side: .right); await client.release(); _ = await restoring.value
        XCTAssertNil(model.current); XCTAssertFalse(model.busy); await model.load(); XCTAssertEqual(model.current?.side, .right)
    }
    func testAlreadyCancelledAndStaleOwnerActionsCannotDispatch() async throws {
        let client = NextAlarmTestClient(scenario: "scheduled"), model = NextAlarmWorkspace()
        model.configure(client: client, side: .left); await model.load()
        let operation = Task { await model.skip() }; operation.cancel(); let cancelled = await operation.value; XCTAssertFalse(cancelled)
        let old = UserDefaults.standard.string(forKey: "ownerConnectionRevision"); defer { UserDefaults.standard.set(old, forKey: "ownerConnectionRevision") }
        UserDefaults.standard.set(UUID().uuidString, forKey: "ownerConnectionRevision")
        XCTAssertFalse(model.isFresh); XCTAssertFalse(model.canChange)
        let changed = await model.skip(); XCTAssertFalse(changed); let count = await client.writeCount; XCTAssertEqual(count, 0)
    }
    func testExpiredReceiptCannotCreateSkipOrRestoreCommands() async throws {
        let clock = AlarmReceiptClock(), client = NextAlarmTestClient(scenario: "scheduled")
        let model = NextAlarmWorkspace(now: { clock.now })
        model.configure(client: client, side: .left); await model.load()
        XCTAssertTrue(model.isFresh); XCTAssertTrue(model.canChange)
        clock.now.addTimeInterval(91)
        XCTAssertFalse(model.isFresh); XCTAssertFalse(model.canChange)
        let skipped = await model.skip(); XCTAssertFalse(skipped)
        let restored = await model.restore(); XCTAssertFalse(restored)
        let count = await client.writeCount; XCTAssertEqual(count, 0)
        await model.load(userInitiated: true); XCTAssertTrue(model.isFresh)
        clock.now.addTimeInterval(-6); XCTAssertFalse(model.isFresh)
    }
    func testOrdinaryDemoReadsSameWeeklyRowsAndCannotSaveOneTimeCommands() async throws {
        let weekly = DemoAlarmClient(scenario: "normal"), client = DemoNextAlarmClient(weekly: weekly, timeZone: "America/Los_Angeles")
        let initial = try await client.read(side: .left); try initial.validate(side: .left); XCTAssertNotNil(initial.alarm); XCTAssertFalse(initial.canChange)
        let rows = try await weekly.all(); await weekly.apply(.init(updates: rows.filter { $0.side == .left }.map { .init(id: $0.id, enabled: false) }))
        let paused = try await client.read(side: .left); XCTAssertNil(paused.alarm); XCTAssertEqual(paused.state, "none")
        let right = try await client.read(side: .right); XCTAssertNotNil(right.alarm)
        do { _ = try await client.write(NextAlarmWrite(base: example("scheduled"), action: "skip")); XCTFail("Demo cannot send a wake command") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Connect")) }
    }
}

private actor NextAlarmTestClient: NextAlarmClient {
    let delegate: SyntheticNextAlarmClient
    private(set) var writeCount = 0
    private var readingFails = false
    private var holding = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(scenario: String) { delegate = .init(scenario: scenario) }
    func available() async throws { try await delegate.available() }
    func read(side: Side) async throws -> NextAlarmState {
        if readingFails { readingFails = false; throw URLError(.notConnectedToInternet) }
        return try await delegate.read(side: side)
    }
    func write(_ input: NextAlarmWrite) async throws -> NextAlarmState {
        writeCount += 1
        if holding { holding = false; await withCheckedContinuation { continuation = $0 } }
        return try await delegate.write(input)
    }
    func failRead() { readingFails = true }
    func hold() { holding = true }
    func waitUntilHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor private final class AlarmReceiptClock { var now = Date() }
