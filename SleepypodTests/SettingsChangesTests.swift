import XCTest
@testable import Sleepypod

@MainActor final class SettingsChangesTests: XCTestCase {
    func testUnitOnlyEditLeavesMaintenanceAndBothSleepersUntouched() async throws {
        let original = try await MockClient().getSettings()
        var desired = original; desired.temperatureFormat = .celsius
        let patch = SettingsChanges(desired: desired, original: original)
        XCTAssertEqual(patch.device.fields, ["temperatureUnit": .string("C")]); XCTAssertTrue(patch.left.isEmpty); XCTAssertTrue(patch.right.isEmpty)
        var current = original; current.rebootTime = "04:45"; current.left.awayMode.toggle(); current.right.name = "Taylor"
        XCTAssertFalse(patch.conflicts(with: current))
        current.temperatureFormat = .celsius; XCTAssertTrue(patch.conflicts(with: current))
    }
    func testAwayToggleOnlyWritesTheSelectedSide() async throws {
        let original = try await MockClient().getSettings()
        var desired = original; desired.right.awayMode.toggle()
        let patch = SettingsChanges(desired: desired, original: original)
        XCTAssertTrue(patch.device.isEmpty); XCTAssertTrue(patch.left.isEmpty)
        XCTAssertEqual(patch.right.fields, ["awayMode": .boolean(desired.right.awayMode)])
    }
    func testEnableDailyMaintenanceIncludesItsDisplayedTime() async throws {
        var original = try await MockClient().getSettings(); original.rebootDaily = false; original.primePodDaily.enabled = false
        var desired = original; desired.rebootDaily = true; desired.primePodDaily.enabled = true
        let patch = SettingsChanges(desired: desired, original: original)
        XCTAssertEqual(Set(patch.device.fields.keys), ["rebootDaily", "rebootTime", "primePodDaily", "primePodTime"])
        var current = original; current.primePodDaily.time = "15:22"
        XCTAssertTrue(patch.conflicts(with: current))
    }
    func testUnchangedSnapshotProducesNoWrites() async throws {
        let original = try await MockClient().getSettings()
        XCTAssertTrue(SettingsChanges(desired: original, original: original).isEmpty)
    }
    func testAppearancePreferencesPersistIndependentlyOfPodUnits() {
        let defaults = UserDefaults.standard
        let keys = ["tempControl", "temperatureDisplay", "temperatureLayout", "stageZones", "stageAutoReturn", "appearance", "temperatureFormat"]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { previous.forEach { defaults.set($0.1, forKey: $0.0) } }
        defaults.set("celsius", forKey: "temperatureFormat")
        let profile = UserProfile()
        profile.tempControl = .sides; profile.temperatureDisplay = .eightSleep; profile.temperatureLayout = .stage
        profile.stageZones = .always; profile.stageAutoReturn = false; profile.appearance = .light
        let restored = UserProfile()
        XCTAssertEqual(restored.tempControl, .sides); XCTAssertEqual(restored.temperatureDisplay, .eightSleep)
        XCTAssertEqual(restored.temperatureLayout, .stage); XCTAssertEqual(restored.stageZones, .always)
        XCTAssertFalse(restored.stageAutoReturn); XCTAssertEqual(restored.appearance, .light)
        XCTAssertEqual(defaults.string(forKey: "temperatureFormat"), "celsius")
    }

}
