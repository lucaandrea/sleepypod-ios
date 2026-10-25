import XCTest

@MainActor
final class CurveParityUITests: XCTestCase {
    private func launch(_ appearance: String = "Dark") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", appearance,
                               "-healthSyncEnabled", "NO", "-uiRoute", "schedule"]
        app.launch()
        XCTAssertTrue(app.buttons["Schedule options"].waitForExistence(timeout: 15))
        app.buttons["Schedule options"].tap(); app.buttons["Curves"].tap()
        XCTAssertTrue(app.navigationBars["Curves"].waitForExistence(timeout: 5))
        return app
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<25 { if element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testCreateClaimDaysEditPointRunOnceAndCancel() {
        let app = launch()
        XCTAssertTrue(app.buttons["curve.edit.1"].waitForExistence(timeout: 4))
        capture(app, "Curves-library-dark")
        let new = app.buttons["curve.new"]; reveal(new, app: app); new.tap()
        XCTAssertTrue(app.navigationBars["New curve"].waitForExistence(timeout: 3))
        app.textFields["Curve name"].tap(); app.textFields["Curve name"].typeText("Calm nights")
        let left = app.buttons["Choose days for Left"]; reveal(left, app: app); left.tap(); app.buttons["Every day"].tap()
        let preset = app.buttons["curve.preset"]; reveal(preset, app: app); preset.tap(); app.buttons["Balanced"].tap()
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Move days and save"].waitForExistence(timeout: 3))
        capture(app, "Curves-day-move-review")
        app.buttons["Move days and save"].tap()
        let created = app.buttons["curve.edit.100"]; XCTAssertTrue(created.waitForExistence(timeout: 4)); reveal(created, app: app); created.tap()
        let point = app.buttons["Edit set point at 21:15"]; reveal(point, app: app); point.tap()
        XCTAssertTrue(app.navigationBars["Set point"].waitForExistence(timeout: 3))
        capture(app, "Curves-point-editor")
        app.navigationBars.buttons["Done"].tap()
        app.navigationBars.buttons["Save"].tap()
        let run = app.buttons["curve.run.100"]; reveal(run, app: app); run.tap()
        XCTAssertTrue(app.navigationBars["Run once"].waitForExistence(timeout: 3))
        capture(app, "Curves-run-once-review")
        let start = app.buttons["Start run once"]; reveal(start, app: app); start.tap()
        let stop = app.buttons["Stop run-once curve"]; XCTAssertTrue(stop.waitForExistence(timeout: 4))
        app.swipeDown(); app.swipeDown(); reveal(stop, app: app); stop.tap()
        XCTAssertTrue(app.staticTexts["Run once cancelled. The recurring schedule resumes."].waitForExistence(timeout: 4))
    }
    func testCurveEditorAtCurrentDeviceTextSize() {
        let app = launch("Light")
        app.buttons["curve.edit.1"].tap()
        XCTAssertTrue(app.navigationBars["Edit curve"].waitForExistence(timeout: 3))
        capture(app, "Curves-responsive-top")
        reveal(app.buttons["curve.endAction"], app: app)
        capture(app, "Curves-responsive-times")
        reveal(app.buttons["curve.preset"], app: app)
        capture(app, "Curves-responsive-preset")
        reveal(app.buttons["Edit set point at 22:00"], app: app)
        capture(app, "Curves-responsive-points")
        app.navigationBars.buttons["Cancel"].tap()
    }
}
