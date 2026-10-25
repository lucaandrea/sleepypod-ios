import XCTest

@MainActor
final class BaseParityUITests: XCTestCase {
    private func launch(_ appearance: String = "Dark") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", appearance,
                               "-healthSyncEnabled", "NO", "-uiRoute", "", "--reset-base-preferences"]
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
        app.buttons["Settings"].tap()
        app.buttons["Bed position"].tap()
        XCTAssertTrue(app.navigationBars["Bed position"].waitForExistence(timeout: 5))
        return app
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<12 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }
    func testBasePreviewFrameRotationSpeedAndSimulatedMovement() {
        let app = launch("Light")
        XCTAssertTrue(app.staticTexts["DEMO · SIMULATED BASE"].exists)
        app.switches["Show mattress"].tap()
        XCTAssertEqual(app.switches["Show mattress"].value as? String, "0")
        let reset = app.buttons["Reset view"]
        reveal(reset, app: app)
        capture(app, "Base-frame-light")
        let start = reset.coordinate(withNormalizedOffset: CGVector(dx: -3, dy: -3))
        let end = reset.coordinate(withNormalizedOffset: CGVector(dx: -1, dy: -3))
        start.press(forDuration: 0.1, thenDragTo: end)
        reset.tap()
        let read = app.buttons["base.preset.both.read"]
        reveal(read, app: app)
        read.tap()
        app.segmentedControls.buttons["75%"].tap()
        let move = app.buttons["base.move.both"]
        XCTAssertTrue(move.isEnabled)
        XCTAssertTrue(move.label.contains("40° / 0°"))
        capture(app, "Base-controls-light")
        move.tap()
        XCTAssertTrue(app.buttons["At target"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Stop"].tap()
        for _ in 0..<8 where !app.switches["Simple bed view"].isHittable { app.swipeDown() }
        app.switches["Simple bed view"].tap()
        XCTAssertEqual(app.switches["Simple bed view"].value as? String, "1")
        app.switches["Show mattress"].tap()
        XCTAssertEqual(app.switches["Show mattress"].value as? String, "1")
        app.swipeUp()
        capture(app, "Base-simple-light")
    }
    func testBaseScheduleCreateEditPauseDeleteAndConflict() {
        let app = launch()
        let add = app.buttons["Add adjustment"]
        reveal(add, app: app)
        add.tap()
        XCTAssertTrue(app.navigationBars["New adjustment"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.navigationBars.buttons["Save"].isEnabled, "The existing daily 22:00 adjustment must conflict")
        app.navigationBars.buttons["Cancel"].tap()
        let delete = app.buttons["Delete Sleep at 22:00"]
        reveal(delete, app: app)
        delete.tap()
        app.buttons["Delete adjustment"].tap()
        XCTAssertTrue(app.staticTexts["No scheduled positions yet."].waitForExistence(timeout: 3))
        add.tap()
        let preset = app.buttons["base.schedule.preset"]
        reveal(preset, app: app)
        preset.tap()
        app.buttons["Read"].tap()
        capture(app, "Base-schedule-editor-dark")
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["base.schedule.2"].waitForExistence(timeout: 3))
        app.buttons["base.schedule.2"].tap()
        XCTAssertTrue(app.navigationBars["Edit adjustment"].waitForExistence(timeout: 3))
        app.switches["Enabled"].tap()
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Paused"].waitForExistence(timeout: 3))
        capture(app, "Base-schedule-paused-dark")
        app.buttons["Delete Read at 22:00"].tap()
        app.buttons["Delete adjustment"].tap()
        XCTAssertTrue(app.staticTexts["No scheduled positions yet."].waitForExistence(timeout: 3))
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testBaseControlsAndEditorAtCurrentDeviceTextSize() {
        let app = launch()
        capture(app, "Base-responsive-top")
        let head = app.sliders["Head angle"]
        reveal(head, app: app)
        head.adjust(toNormalizedSliderPosition: 0.5)
        let read = app.buttons["base.preset.both.read"]
        reveal(read, app: app)
        read.tap()
        let move = app.buttons["base.move.both"]
        XCTAssertTrue(move.label.contains("40° / 0°"))
        capture(app, "Base-responsive-controls")
        let add = app.buttons["Add adjustment"]
        reveal(add, app: app)
        add.tap()
        XCTAssertTrue(app.navigationBars["New adjustment"].waitForExistence(timeout: 3))
        capture(app, "Base-responsive-editor")
        let preset = app.buttons["base.schedule.preset"]
        reveal(preset, app: app)
        preset.tap()
        app.buttons["Read"].tap()
        capture(app, "Base-responsive-editor-position")
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Stop"].exists)
    }
}
