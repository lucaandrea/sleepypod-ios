import XCTest
@testable import Sleepypod

@MainActor final class SleeperPreferencesTests: XCTestCase {
    func testExclusiveFlagsAreSentAtomicallyAndReturnDateCanBeCleared() {
        var saved = SleeperPreferences.demo(.left); saved.awayReturn = "2026-11-01T12:00:00Z"
        var draft = saved; draft.alwaysOn = true; draft.awayReturn = nil
        XCTAssertEqual(draft.patch(from: saved).fields, ["alwaysOn": .boolean(true), "autoOffEnabled": .boolean(false), "awayReturn": .null])
        draft = saved; draft.autoOffEnabled = true
        XCTAssertEqual(draft.patch(from: saved).fields, ["autoOffEnabled": .boolean(true), "alwaysOn": .boolean(false)])
    }
    func testNamesUseServerUTF16LimitAndAwayRangesAreAbsolute() {
        var value = SleeperPreferences.demo(.left)
        value.name = String(repeating: "😀", count: 10); XCTAssertNil(value.issue)
        value.name += "a"; XCTAssertNotNil(value.issue)
        value.name = "Alex"; value.awayStart = "2026-11-01T12:00:00Z"; value.awayReturn = "2026-11-01T11:59:00Z"
        XCTAssertNotNil(value.issue)
        value.awayReturn = "2026-11-01T12:00:00.000Z"; XCTAssertNil(value.issue)
        value.autoOnStart = "24:00"; XCTAssertNotNil(value.issue)
    }
    func testFailedReadNeverInventsEditableProfiles() async {
        let model = SleeperPreferencesWorkspace(client: SleeperFixture(failReads: true))
        await model.load(); XCTAssertNil(model.draft); XCTAssertNotNil(model.error)
    }
    func testBedSavePreservesOtherSideDraftAndRemoteFields() async throws {
        let client = SleeperFixture(), model = SleeperPreferencesWorkspace(client: client)
        await model.load(); model.draft?.device.bedMode = "solo-right"; model.draft?.sides.left.autoOnMinutes = 9
        try await client.change(.right, patch: .init(fields: ["name": .string("Taylor")]))
        await model.saveBed()
        XCTAssertEqual(model.saved?.device.bedMode, "solo-right")
        XCTAssertEqual(model.draft?.sides.right.name, "Taylor")
        XCTAssertEqual(model.draft?.sides.left.autoOnMinutes, 9)
        XCTAssertEqual(model.saved?.sides.left.autoOnMinutes, 5)
        let patches = await client.bedPatches; XCTAssertEqual(patches.map(\.fields), [["bedMode": .string("solo-right")]])
    }
    func testNameSavePreservesPendingProfileEditsAndOnlyWritesName() async {
        let client = SleeperFixture(), model = SleeperPreferencesWorkspace(client: client)
        await model.load(); model.draft?.sides.left.autoOnMinutes = 9
        await model.saveName(.left, name: "  Luca  ")
        XCTAssertEqual(model.saved?.sides.left.name, "Luca"); XCTAssertEqual(model.draft?.sides.left.autoOnMinutes, 9)
        let patches = await client.sidePatches; XCTAssertEqual(patches.map(\.fields), [["name": .string("Luca")]])
    }
    func testUnavailablePresenceBlocksEnablingButAllowsDisabling() async {
        let client = SleeperFixture(available: false), model = SleeperPreferencesWorkspace(client: client)
        await model.load(); model.draft?.sides.left.autoOffEnabled = true
        await model.saveSide(.left)
        let blocked = await client.sidePatches; XCTAssertTrue(blocked.isEmpty); XCTAssertTrue(model.error?.contains("Presence is unavailable") == true)
        await client.setEnabled(); await model.load(discard: true); model.draft?.sides.left.autoOffEnabled = false
        await model.saveSide(.left)
        let writes = await client.sidePatches; XCTAssertEqual(writes.map(\.fields), [["autoOffEnabled": .boolean(false)]])
    }
    func testPresenceMustBeFreshAndRecheckedAtSave() async {
        let client = SleeperFixture(), model = SleeperPreferencesWorkspace(client: client)
        await model.load(); await model.refreshOccupancy()
        XCTAssertTrue(model.presenceAvailable(.left)); XCTAssertFalse(model.presenceAvailable(.left, now: .now.addingTimeInterval(26)))
        model.draft?.sides.left.autoOnEnabled = true; await client.setAvailable(false)
        await model.saveSide(.left)
        let writes = await client.sidePatches; XCTAssertTrue(writes.isEmpty)
    }
    func testConcurrentEditedFieldBlocksSaveAndRetainsDraft() async throws {
        let client = SleeperFixture(), model = SleeperPreferencesWorkspace(client: client)
        await model.load(); model.draft?.sides.left.autoOnMinutes = 9
        try await client.change(.left, patch: .init(fields: ["autoOnMinutes": .integer(12)]))
        await model.saveSide(.left)
        XCTAssertTrue(model.mustReload); XCTAssertEqual(model.draft?.sides.left.autoOnMinutes, 9)
        let writes = await client.sidePatches; XCTAssertTrue(writes.isEmpty)
    }
    func testMergedAwayStartIsValidatedBeforeMutation() async throws {
        let client = SleeperFixture(), model = SleeperPreferencesWorkspace(client: client)
        await model.load(); model.draft?.sides.left.awayReturn = "2026-11-01T12:00:00Z"
        try await client.change(.left, patch: .init(fields: ["awayStart": .string("2026-11-02T12:00:00Z")]))
        await model.saveSide(.left)
        let writes = await client.sidePatches; XCTAssertTrue(writes.isEmpty); XCTAssertTrue(model.error?.contains("Return") == true)
    }
    func testUnknownSaveRequiresReloadAndNeverReplays() async {
        let client = SleeperFixture(failWrites: true), model = SleeperPreferencesWorkspace(client: client)
        await model.load(); model.draft?.sides.left.awayMode = true
        await model.saveSide(.left); await model.saveSide(.left)
        let writes = await client.sidePatches; XCTAssertEqual(writes.count, 1); XCTAssertTrue(model.mustReload); XCTAssertNil(model.receipt)
        await model.load(discard: true); XCTAssertFalse(model.mustReload)
    }
    func testAcknowledgedSaveAndFailedReadbackStayDistinct() async {
        let model = SleeperPreferencesWorkspace(client: SleeperFixture(failReadback: true))
        await model.load(); model.draft?.device.unusedZoneMode = "follow"
        await model.saveBed(); XCTAssertNotNil(model.receipt); XCTAssertTrue(model.mustReload); XCTAssertTrue(model.error?.contains("acknowledged") == true)
    }
}
private actor SleeperFixture: SleeperPreferencesClient {
    var value = SleeperPreferencesSnapshot.demo
    var bedPatches: [SettingsFieldPatch] = []
    var sidePatches: [SettingsFieldPatch] = []
    var available: Bool
    let failReads: Bool
    let failWrites: Bool
    let failReadback: Bool
    init(available: Bool = true, failReads: Bool = false, failWrites: Bool = false, failReadback: Bool = false) {
        self.available = available; self.failReads = failReads; self.failWrites = failWrites; self.failReadback = failReadback
    }
    func settings() throws -> SleeperPreferencesSnapshot {
        if failReads || (failReadback && !bedPatches.isEmpty) { throw URLError(.notConnectedToInternet) }
        return value
    }
    func saveBed(_ patch: SettingsFieldPatch) throws {
        bedPatches.append(patch); if failWrites { throw URLError(.timedOut) }
        if case .string(let mode) = patch.fields["bedMode"] { value.device.bedMode = mode }
        if case .string(let mode) = patch.fields["unusedZoneMode"] { value.device.unusedZoneMode = mode }
    }
    func saveSide(_ side: Side, patch: SettingsFieldPatch) throws {
        sidePatches.append(patch); if failWrites { throw URLError(.timedOut) }
        try change(side, patch: patch)
    }
    func change(_ side: Side, patch: SettingsFieldPatch) throws { value.sides[side] = try value.sides[side].merging(patch) }
    func setEnabled() { value.sides.left.autoOffEnabled = true }
    func setAvailable(_ value: Bool) { available = value }
    func occupancy() -> SensorOccupancy {
        let side = SensorOccupancy.BedSide(occupied: false, available: available, classification: "empty", movement: .init(active: false, peakScore: 0), level: .init(active: false, deviation: nil, threshold: nil, ageMs: 1000, zoneDeviations: nil, zones: nil), vitals: .init(heartRate: nil, breathingRate: nil, humanRange: false))
        return .init(left: side, right: side)
    }
}
