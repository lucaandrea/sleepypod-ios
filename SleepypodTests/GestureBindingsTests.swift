import XCTest
@testable import Sleepypod

@MainActor final class GestureBindingsTests: XCTestCase {
    func testDraftEncodesOnlyActiveActionAndPreservesSnoozeSeconds() {
        let record = GestureBinding(side: .left, tapType: .doubleTap, actionType: "alarm", temperatureChange: nil, temperatureAmount: nil, alarmBehavior: "snooze", alarmSnoozeDuration: 90, alarmInactiveBehavior: "power")
        var draft = GestureDraft(side: .left, tap: .doubleTap, original: record)
        XCTAssertEqual(draft.fields["alarmSnoozeDuration"], .integer(90)); XCTAssertNil(draft.fields["temperatureAmount"])
        draft.actionType = "temperature"; draft.temperatureChange = "decrement"; draft.temperatureAmount = 10
        XCTAssertNil(draft.fields["alarmSnoozeDuration"]); XCTAssertEqual(draft.binding.idleDescription, "Temperature −10°F")
        XCTAssertNil(draft.issue); draft.temperatureAmount = 11; XCTAssertNotNil(draft.issue)
        draft.temperatureAmount = 0; XCTAssertNil(draft.issue)
    }
    func testMissingBindingsStayMissingUntilAnEditorIsOpenedAndSaved() async {
        let model = GestureBindingsWorkspace(client: DemoGestureBindingsClient())
        await model.load(); XCTAssertNil(model.saved?.gestures.binding(.right, tap: .quadTap)); XCTAssertNil(model.editing)
        model.open(.right, tap: .quadTap); XCTAssertNotNil(model.editing); XCTAssertNil(model.original)
        await model.save(); XCTAssertNotNil(model.saved?.gestures.binding(.right, tap: .quadTap)); XCTAssertNil(model.editing)
    }
    func testFailedReadDoesNotCreateDefaults() async {
        let model = GestureBindingsWorkspace(client: GestureFixture(failReads: true))
        await model.load(); model.open(.left, tap: .doubleTap)
        XCTAssertNil(model.saved); XCTAssertNil(model.editing); XCTAssertNotNil(model.error)
    }
    func testSelectedMappingConflictPreventsSave() async {
        let client = GestureFixture(), model = GestureBindingsWorkspace(client: client)
        await model.load(); model.open(.left, tap: .doubleTap)
        await client.add(.left, tap: .doubleTap); await model.save()
        XCTAssertTrue(model.mustReload); XCTAssertNotNil(model.editing)
        let writes = await client.writes; XCTAssertEqual(writes, 0)
    }
    func testOtherSideMappingChangeDoesNotBlockSave() async {
        let client = GestureFixture(), model = GestureBindingsWorkspace(client: client)
        await model.load(); model.open(.left, tap: .doubleTap)
        await client.add(.right, tap: .tripleTap); await model.save()
        XCTAssertNotNil(model.saved?.gestures.binding(.right, tap: .tripleTap)); XCTAssertNotNil(model.saved?.gestures.binding(.left, tap: .doubleTap))
    }
    func testUnknownSaveIsNotReplayed() async {
        let client = GestureFixture(failWrites: true), model = GestureBindingsWorkspace(client: client)
        await model.load(); model.open(.left, tap: .doubleTap)
        await model.save(); await model.save()
        let writes = await client.writes; XCTAssertEqual(writes, 1); XCTAssertTrue(model.mustReload); XCTAssertNil(model.receipt)
    }
    func testUnknownRemovalIsNotReplayed() async {
        let client = GestureFixture(failWrites: true), model = GestureBindingsWorkspace(client: client)
        await client.add(.right, tap: .quadTap)
        await model.load(); model.open(.right, tap: .quadTap)
        await model.remove(); await model.remove()
        let writes = await client.writes; XCTAssertEqual(writes, 1); XCTAssertTrue(model.mustReload)
        await model.load(discard: true); XCTAssertNil(model.editing); XCTAssertFalse(model.mustReload)
    }
    func testReadbackFailureDoesNotHideAcknowledgment() async {
        let model = GestureBindingsWorkspace(client: GestureFixture(failReadback: true))
        await model.load(); model.open(.left, tap: .doubleTap); await model.save()
        XCTAssertEqual(model.receipt, "Gesture saved."); XCTAssertTrue(model.mustReload); XCTAssertTrue(model.error?.contains("acknowledged") == true)
    }
}
private actor GestureFixture: GestureBindingsClient {
    var value = GestureBindingsSnapshot.demo
    var writes = 0
    let failReads: Bool
    let failWrites: Bool
    let failReadback: Bool
    init(failReads: Bool = false, failWrites: Bool = false, failReadback: Bool = false) { self.failReads = failReads; self.failWrites = failWrites; self.failReadback = failReadback }
    func settings() throws -> GestureBindingsSnapshot {
        if failReads || (failReadback && writes > 0) { throw URLError(.notConnectedToInternet) }
        return value
    }
    func add(_ side: Side, tap: CoverTap) { value.gestures.set(GestureDraft(side: side, tap: tap, original: nil).binding, side: side, tap: tap) }
    func save(_ draft: GestureDraft) throws {
        writes += 1; if failWrites { throw URLError(.timedOut) }
        value.gestures.set(draft.binding, side: draft.side, tap: draft.tap)
    }
    func remove(side: Side, tap: CoverTap) throws {
        writes += 1; if failWrites { throw URLError(.timedOut) }
        value.gestures.set(nil, side: side, tap: tap)
    }
}
