import XCTest
@testable import Sleepypod

@MainActor final class SettingsLifecycleTests: XCTestCase {
    func testLegacySettingsWithoutRebootClockDecodeAndRoundTrip() async throws {
        let fixture = try await MockClient().getSettings()
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture)) as? [String: Any])
        wire.removeValue(forKey: "rebootTime")
        let data = try JSONSerialization.data(withJSONObject: wire)
        let settings = try JSONDecoder().decode(PodSettings.self, from: data)
        XCTAssertNil(settings.rebootTime)
        XCTAssertEqual(settings.timeZone, fixture.timeZone)
        XCTAssertEqual(settings.left.name, fixture.left.name)
        guard case .alarm(let behavior, let duration, _) = settings.right.taps.quadTap else { return XCTFail("Alarm gesture lost") }
        XCTAssertEqual(behavior, .snooze); XCTAssertEqual(duration, 300)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        XCTAssertNil(encoded["rebootTime"], "Legacy saves must not add a field rejected by the server's strict schema")
        wire.removeValue(forKey: "timeZone")
        XCTAssertThrowsError(try JSONDecoder().decode(PodSettings.self, from: JSONSerialization.data(withJSONObject: wire)))
    }

    func testBackendSwitchDiscardsAnOldRead() async throws {
        let restore = preserveDisplayDefaults(); defer { restore() }
        var oldValue = try await MockClient().getSettings(); oldValue.left.name = "Previous Pod"
        let oldGate = SettingsAsyncGate(value: oldValue, holdRead: true)
        let manager = SettingsManager(api: SettingsAsyncClient(gate: oldGate))
        let oldRead = Task { await manager.fetchSettings() }; await oldGate.waitForRead()
        let replacement = MockClient(); let expected = try await replacement.getSettings()
        manager.switchBackend(replacement); XCTAssertFalse(manager.isLoading)
        await manager.fetchSettings(); await oldGate.releaseRead(); await oldRead.value
        XCTAssertEqual(manager.leftName, expected.left.name); XCTAssertFalse(manager.isLoading)
    }
    func testOldSaveCannotReplaceNewBackendOrClearItsBusyState() async throws {
        let restore = preserveDisplayDefaults(); defer { restore() }
        let original = try await MockClient().getSettings()
        let first = SettingsAsyncGate(value: original, holdSave: true)
        let manager = SettingsManager(api: SettingsAsyncClient(gate: first)); await manager.fetchSettings()
        let oldSave = Task { await manager.updateTemperatureFormat(.celsius) }; await first.waitForSave()
        var next = original; next.left.name = "New Pod"
        let second = SettingsAsyncGate(value: next, holdSave: true)
        manager.switchBackend(SettingsAsyncClient(gate: second)); await manager.fetchSettings()
        let newSave = Task { await manager.toggleAwayMode(.right) }; await second.waitForSave()
        await first.releaseSave(); await oldSave.value
        XCTAssertEqual(manager.leftName, "New Pod"); XCTAssertTrue(manager.isSaving); XCTAssertEqual(manager.temperatureFormat, .fahrenheit)
        await second.releaseSave(); await newSave.value
        XCTAssertEqual(manager.settings?.right.awayMode, !next.right.awayMode); XCTAssertFalse(manager.isSaving)
    }
    func testConcurrentSaveAndFetchCannotEraseOrRepeatPendingWrite() async throws {
        let restore = preserveDisplayDefaults(); defer { restore() }
        let original = try await MockClient().getSettings(), gate = SettingsAsyncGate(value: try await MockClient().getSettings(), holdSave: true)
        let manager = SettingsManager(api: SettingsAsyncClient(gate: gate)); await manager.fetchSettings()
        let pending = Task { await manager.updateTemperatureFormat(.celsius) }; await gate.waitForSave()
        await manager.fetchSettings(); await manager.toggleAwayMode(.left)
        let counts = await gate.counts(); XCTAssertEqual(counts.reads, 1); XCTAssertEqual(counts.writes, 1)
        XCTAssertEqual(manager.settings?.left.awayMode, original.left.awayMode); XCTAssertEqual(manager.temperatureFormat, original.temperatureFormat)
        await gate.releaseSave(); await pending.value
        XCTAssertEqual(manager.temperatureFormat, .celsius); XCTAssertFalse(manager.isSaving)
    }
}
private final class SettingsAsyncClient: MockAPIClient, @unchecked Sendable {
    let gate: SettingsAsyncGate
    init(gate: SettingsAsyncGate) { self.gate = gate; super.init() }
    override func getSettings() async throws -> PodSettings { await gate.read() }
    override func updateSettings(_ settings: PodSettings) async throws -> PodSettings { await gate.save(settings) }
}
private actor SettingsAsyncGate {
    var value: PodSettings
    let holdRead: Bool
    let holdSave: Bool
    private var reads = 0
    private var writes = 0
    private var readContinuation: CheckedContinuation<Void, Never>?
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private var readObserver: CheckedContinuation<Void, Never>?
    private var saveObserver: CheckedContinuation<Void, Never>?
    init(value: PodSettings, holdRead: Bool = false, holdSave: Bool = false) { self.value = value; self.holdRead = holdRead; self.holdSave = holdSave }
    func read() async -> PodSettings {
        reads += 1
        if holdRead {
            await withCheckedContinuation { readContinuation = $0; readObserver?.resume(); readObserver = nil }
        }
        return value
    }
    func save(_ desired: PodSettings) async -> PodSettings {
        writes += 1
        if holdSave {
            await withCheckedContinuation { saveContinuation = $0; saveObserver?.resume(); saveObserver = nil }
        }
        value = desired; return value
    }
    func waitForRead() async { if readContinuation == nil { await withCheckedContinuation { readObserver = $0 } } }
    func waitForSave() async { if saveContinuation == nil { await withCheckedContinuation { saveObserver = $0 } } }
    func releaseRead() { readContinuation?.resume(); readContinuation = nil }
    func releaseSave() { saveContinuation?.resume(); saveContinuation = nil }
    func counts() -> (reads: Int, writes: Int) { (reads, writes) }
}

private func preserveDisplayDefaults() -> () -> Void {
    let defaults = UserDefaults.standard
    let temperature = defaults.object(forKey: "temperatureFormat"), clock = defaults.object(forKey: "podTimeFormat")
    return { defaults.set(temperature, forKey: "temperatureFormat"); defaults.set(clock, forKey: "podTimeFormat") }
}
