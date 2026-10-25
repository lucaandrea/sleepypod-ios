import XCTest

@MainActor
final class AlarmParityUITests: XCTestCase {
    private func launch(_ appearance: String = "Dark") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", appearance,
                               "-healthSyncEnabled", "NO", "-uiRoute", "schedule"]
        app.launch()
        XCTAssertTrue(app.buttons["Schedule options"].waitForExistence(timeout: 15))
        app.buttons["Schedule options"].tap(); app.buttons["Alarms"].tap()
        XCTAssertTrue(app.navigationBars["Alarms"].waitForExistence(timeout: 5))
        return app
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<18 { if element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testAlarmCreateSmartWakeSnoozePauseAndDelete() {
        let app = launch()
        let add = app.buttons["alarm.add.left"]; reveal(add, app: app); add.tap()
        XCTAssertTrue(app.navigationBars["New alarm"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.navigationBars.buttons["Save"].isEnabled)
        let weekends = app.buttons["Weekends"]; reveal(weekends, app: app); weekends.tap()
        let wake = app.buttons["alarm.wakeWindow"]; reveal(wake, app: app); wake.tap(); app.buttons["20 min"].tap()
        let taper = app.buttons["alarm.snoozeTaper"]; reveal(taper, app: app); taper.tap(); app.buttons["40%"].tap()
        capture(app, "Alarm-wake-and-snooze-dark")
        let test = app.buttons["Test vibration"]; reveal(test, app: app); test.tap()
        let stop = app.buttons["alarm.test.stop.editor"]; reveal(stop, app: app); stop.tap()
        app.navigationBars.buttons["Save"].tap()
        let created = app.buttons["alarm.edit.100,101"]; XCTAssertTrue(created.waitForExistence(timeout: 4)); reveal(created, app: app)
        capture(app, "Alarm-groups-dark")
        created.tap()
        XCTAssertTrue(app.navigationBars["Edit alarm"].waitForExistence(timeout: 3))
        app.switches["Alarm enabled"].tap()
        app.navigationBars.buttons["Save"].tap()
        let paused = app.buttons["alarm.edit.102,103"]; XCTAssertTrue(paused.waitForExistence(timeout: 4))
        reveal(paused, app: app); paused.tap()
        reveal(app.buttons["alarm.wakeWindow"], app: app)
        XCTAssertTrue(app.buttons["alarm.wakeWindow"].label.contains("20 min"))
        reveal(app.buttons["alarm.snoozeTaper"], app: app)
        XCTAssertTrue(app.buttons["alarm.snoozeTaper"].label.contains("40%"))
        app.navigationBars.buttons["Cancel"].tap()
        let deletes = app.buttons.matching(identifier: "Delete alarm at 07:00")
        reveal(deletes.element(boundBy: 1), app: app); deletes.element(boundBy: 1).tap()
        app.buttons["Delete alarm"].tap()
        XCTAssertFalse(paused.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["alarm.edit.1,2,3,4,5,6,7"].exists, "The existing daily alarm must remain")
    }
    func testAlarmEditorAtCurrentDeviceTextSize() {
        let app = launch("Light")
        let original = app.buttons["alarm.edit.1,2,3,4,5,6,7"]; reveal(original, app: app); original.tap()
        XCTAssertTrue(app.navigationBars["Edit alarm"].waitForExistence(timeout: 3))
        capture(app, "Alarm-responsive-top")
        reveal(app.buttons["alarm.wakeWindow"], app: app); app.buttons["alarm.wakeWindow"].tap(); app.buttons["30 min"].tap()
        capture(app, "Alarm-responsive-wake")
        reveal(app.buttons["alarm.snoozeTaper"], app: app); app.buttons["alarm.snoozeTaper"].tap(); app.buttons["50%"].tap()
        capture(app, "Alarm-responsive-snooze")
        reveal(app.staticTexts["TEMPERATURE AT WAKE"], app: app)
        capture(app, "Alarm-responsive-temperature")
        app.navigationBars.buttons["Cancel"].tap()
    }
    func testNextAlarmToggleAndEditorOnTemperatureScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", "Dark",
                               "-healthSyncEnabled", "NO", "-uiRoute", "", "-tempControl", "dial", "-temperatureLayout", "cards"]
        app.launch()
        let toggle = app.switches["Next alarm enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        XCTAssertEqual(toggle.value as? String, "1")
        // tap() scrolls to this control; a generic swipe can be consumed by the temperature dial.
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        capture(app, "Alarm-next-paused-dark")
        app.buttons["Edit next alarm at 07:00"].tap()
        XCTAssertTrue(app.navigationBars["Edit alarm"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.switches["Alarm enabled"].value as? String, "0")
        app.navigationBars.buttons["Cancel"].tap()
    }
}
