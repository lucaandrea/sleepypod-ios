import XCTest
@testable import Sleepypod

@MainActor final class DevicePreferencesTests: XCTestCase {
    func testClockPreferenceChangesDisplayWithoutChangingWallClockMinutes() {
        XCTAssertEqual(DisplayTime.clock(minutes: 0, format: "24h"), "00:00")
        XCTAssertEqual(DisplayTime.clock(minutes: 1439, format: "24h"), "23:59")
        XCTAssertEqual(DisplayTime.clock(minutes: 1440 + 75, format: "24h"), "01:15")
        XCTAssertEqual(DisplayTime.clock(minutes: -60, format: "12h"), "11:00 PM")
        XCTAssertEqual(DisplayTime.tick(minutes: 720, format: "12h"), "12 PM")
        XCTAssertEqual(DisplayTime.tick(minutes: 720, format: "24h"), "12:00")
        XCTAssertEqual(DisplayTime.minutes("14:30"), 870)
        let locale = DevicePreferences.clockLocale(format: "24h", base: Locale(identifier: "fr_FR"))
        XCTAssertEqual(locale.hourCycle, .zeroToTwentyThree)
        XCTAssertEqual(locale.language.languageCode?.identifier, "fr")
        XCTAssertEqual(DevicePreferences.clockLocale(format: "12h", base: locale).hourCycle, .oneToTwelve)
    }
    func testPatchOmitsUnchangedFieldsAndExplicitlyClearsPowerCap() throws {
        let saved = DevicePreferences.demo
        var draft = saved; draft.globalMaxOnHours = nil; draft.ledDayBrightness = 40
        let patch = draft.patch(from: saved)
        XCTAssertEqual(Set(patch.fields.keys), ["globalMaxOnHours", "ledDayBrightness"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any])
        XCTAssertTrue(body["globalMaxOnHours"] is NSNull)
        XCTAssertEqual(body["ledDayBrightness"] as? Int, 40)
        XCTAssertNil(body["timezone"]); XCTAssertNil(body["homekitEnabled"])
    }
    func testValidationRejectsBadTimesRangesAndMissingEnabledTimes() {
        var draft = DevicePreferences.demo
        draft.rebootTime = "24:00"; XCTAssertNotNil(draft.issue)
        draft.rebootTime = nil; XCTAssertNil(draft.issue)
        draft.rebootDaily = true; XCTAssertNotNil(draft.issue)
        draft.rebootTime = "03:00"; draft.globalMaxOnHours = 49; XCTAssertNotNil(draft.issue)
        draft.globalMaxOnHours = 1; draft.ledNightBrightness = 101; XCTAssertNotNil(draft.issue)
        draft.ledNightBrightness = 0; draft.timezone = "Invalid/Timezone"; XCTAssertNotNil(draft.issue)
        XCTAssertFalse(DevicePreferences.validClock("1:00"))
        XCTAssertTrue(DevicePreferences.validClock("23:59"))
    }
    func testReadFailureCannotInventEditableDefaults() async {
        let model = DevicePreferencesWorkspace(client: DevicePreferenceFixture(failReads: true))
        await model.load()
        XCTAssertNil(model.draft); XCTAssertNotNil(model.error)
    }
    func testUnrelatedRemoteChangeIsPreservedByTargetedPatch() async throws {
        let client = DevicePreferenceFixture(), model = DevicePreferencesWorkspace(client: client)
        await model.load(); model.draft?.ledDayBrightness = 40
        try await client.change(.init(fields: ["timezone": .string("Europe/Paris")]))
        await model.save()
        XCTAssertEqual(model.saved?.timezone, "Europe/Paris")
        XCTAssertEqual(model.saved?.ledDayBrightness, 40)
        let patches = await client.patches
        XCTAssertEqual(patches.map(\.fields), [["ledDayBrightness": .integer(40)]])
    }
    func testSameFieldConflictRetainsDraftAndPreventsWrite() async throws {
        let client = DevicePreferenceFixture(), model = DevicePreferencesWorkspace(client: client)
        await model.load(); model.draft?.ledDayBrightness = 40
        try await client.change(.init(fields: ["ledDayBrightness": .integer(60)]))
        await model.save()
        XCTAssertTrue(model.mustReload); XCTAssertEqual(model.draft?.ledDayBrightness, 40)
        let patches = await client.patches; XCTAssertTrue(patches.isEmpty)
    }
    func testUnknownSaveIsNeverAutomaticallyReplayed() async {
        let client = DevicePreferenceFixture(failWrites: true), model = DevicePreferencesWorkspace(client: client)
        await model.load(); model.draft?.primePodDaily = true
        await model.save(); await model.save()
        let count = await client.patches.count
        XCTAssertEqual(count, 1); XCTAssertTrue(model.mustReload); XCTAssertNil(model.receipt)
        await model.load(discardDraft: true)
        XCTAssertFalse(model.mustReload); XCTAssertFalse(model.dirty)
    }
    func testAcknowledgmentAndReadbackFailureRemainDistinct() async {
        let client = DevicePreferenceFixture(failReadback: true), model = DevicePreferencesWorkspace(client: client)
        await model.load(); model.draft?.timeFormat = "24h"
        await model.save()
        XCTAssertNotNil(model.receipt); XCTAssertTrue(model.mustReload)
        XCTAssertTrue(model.error?.contains("acknowledged") == true)
    }
    func testOrdinaryRefreshDoesNotDiscardDraftAndSourcePollingDoesNotTouchIt() async {
        let model = DevicePreferencesWorkspace(client: DemoDevicePreferencesClient())
        await model.load(); model.draft?.ledDayBrightness = 27
        await model.load(); await model.refreshSource()
        XCTAssertEqual(model.draft?.ledDayBrightness, 27); XCTAssertNotNil(model.source)
        await model.load(discardDraft: true); XCTAssertEqual(model.draft?.ledDayBrightness, 80)
    }
    func testSensorSourceGraceStallAndConnectionFreshness() {
        let firmware = SensorSourceSnapshot.demo.firmware
        func snapshot(source: String = "nats", age: Double?, uptime: Double = 1800, override: String? = nil) -> SensorSourceSnapshot {
            .init(firmware: firmware, stream: .init(source: source, override: override, legacyNatsDisabled: false, lastFrameAgeMs: age, lastFrameType: "capSense2", uptimeSeconds: uptime))
        }
        XCTAssertEqual(snapshot(source: "pending", age: nil).status(), "Choosing")
        XCTAssertEqual(snapshot(age: nil, uptime: 50).status(), "Waiting")
        XCTAssertEqual(snapshot(age: nil, uptime: 90).status(), "No frames")
        XCTAssertEqual(snapshot(age: 60_000).status(), "Live")
        XCTAssertEqual(snapshot(age: 60_000).status(elapsed: 1), "Stalled")
        XCTAssertEqual(snapshot(age: 1).status(elapsed: 26), "Refresh needed")
        XCTAssertTrue(snapshot(source: "raw", age: 1).note?.contains("differs") == true)
        XCTAssertTrue(snapshot(source: "raw", age: 1, override: "raw").note?.contains("forces") == true)
    }
    func testRestartAcknowledgmentRequiresReconnectWithoutClaimingCompletion() async {
        let model = DevicePreferencesWorkspace(client: DemoDevicePreferencesClient())
        await model.load(); await model.refreshSource(); await model.restart()
        XCTAssertTrue(model.restartNeedsReconnect); XCTAssertTrue(model.mustReload); XCTAssertNil(model.source)
        XCTAssertTrue(model.restartReceipt?.contains("requested") == true)
        await model.load()
        XCTAssertFalse(model.restartNeedsReconnect)
        XCTAssertEqual(model.restartReceipt, "The controller responded to reconnect.")
    }
    func testLostRestartResponseCannotBeReplayedUntilReconnect() async {
        let client = DevicePreferenceFixture(failWrites: true), model = DevicePreferencesWorkspace(client: client)
        await model.load(); await model.restart(); await model.restart()
        let count = await client.restarts
        XCTAssertEqual(count, 1); XCTAssertTrue(model.restartNeedsReconnect)
        XCTAssertNil(model.restartReceipt); XCTAssertTrue(model.error?.contains("not confirmed") == true)
    }
    func testExplicitRestartDenialIsAnErrorAndDraftBlocksRestart() async {
        let client = DevicePreferenceFixture(denyRestart: true), model = DevicePreferencesWorkspace(client: client)
        await model.load(); model.draft?.ledDayBrightness = 22; await model.restart()
        let before = await client.restarts; XCTAssertEqual(before, 0)
        await model.load(discardDraft: true); await model.restart()
        XCTAssertFalse(model.restartNeedsReconnect); XCTAssertNil(model.restartReceipt)
        XCTAssertEqual(model.error, "Permission denied in fixture")
    }
}
private actor DevicePreferenceFixture: DevicePreferencesClient {
    private let demo = DemoDevicePreferencesClient()
    private let failReads: Bool
    private let failWrites: Bool
    private let failReadback: Bool
    private let denyRestart: Bool
    private(set) var patches: [SettingsFieldPatch] = []
    private(set) var restarts = 0
    init(failReads: Bool = false, failWrites: Bool = false, failReadback: Bool = false, denyRestart: Bool = false) {
        self.failReads = failReads; self.failWrites = failWrites; self.failReadback = failReadback
        self.denyRestart = denyRestart
    }
    func settings() async throws -> DevicePreferences {
        if failReads || (failReadback && !patches.isEmpty) { throw APIError.noBaseURL }
        return await demo.settings()
    }
    func change(_ patch: SettingsFieldPatch) async throws { try await demo.save(patch) }
    func save(_ patch: SettingsFieldPatch) async throws {
        patches.append(patch)
        if failWrites { throw APIError.noBaseURL }
        try await demo.save(patch)
    }
    func sensorSource() -> SensorSourceSnapshot { .demo }
    func restart() throws -> HealthServiceRestart {
        restarts += 1
        if failWrites { throw APIError.noBaseURL }
        return .init(ok: !denyRestart, message: denyRestart ? "Permission denied in fixture" : "Requested")
    }
}
