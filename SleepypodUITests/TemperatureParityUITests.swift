import XCTest

@MainActor
final class TemperatureParityUITests: XCTestCase {
    private func launch(layout: String = "stage", appearance: String = "Dark") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", appearance,
                               "-healthSyncEnabled", "NO", "-uiRoute", "", "-tempControl", "dial",
                               "-temperatureLayout", layout, "-temperatureDisplay", "eightSleep", "-stageZones", "always", "-stageAutoReturn", "NO"]
        app.launch()
        XCTAssertTrue(app.segmentedControls.buttons["Cards"].waitForExistence(timeout: 15))
        return app
    }

    func testStageSelectionCameraAndReadOnlySchedulePreview() {
        let app = launch()
        let selectRight = app.buttons["Select Right"]
        XCTAssertTrue(selectRight.waitForExistence(timeout: 10))
        selectRight.tap()
        let camera = app.buttons["Reset view"]
        XCTAssertTrue(camera.exists)
        let start = camera.coordinate(withNormalizedOffset: CGVector(dx: -1.4, dy: -4))
        let end = camera.coordinate(withNormalizedOffset: CGVector(dx: -0.3, dy: -5))
        start.press(forDuration: 0.1, thenDragTo: end)
        capture(app, "Stage-rotated")
        camera.tap()
        capture(app, "Stage-live")
        let slider = app.sliders["Preview tonight's schedule"]
        for _ in 0..<5 where !slider.isHittable { app.swipeUp() }
        XCTAssertTrue(slider.isHittable)
        slider.adjust(toNormalizedSliderPosition: 0.6)
        let back = app.buttons["Back to live"]
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        capture(app, "Stage-schedule-preview")
        back.tap()
        XCTAssertFalse(app.buttons["Back to live"].exists)
        app.swipeDown()
        app.segmentedControls.buttons["Cards"].tap()
        XCTAssertTrue(app.otherElements["Target temperature"].exists || app.staticTexts["Target temperature"].exists)
        capture(app, "Cards-eight-sleep")
    }

    func testAppearanceChoicesPreserveNativeControls() {
        let app = launch(layout: "cards", appearance: "Light")
        app.buttons["Settings"].tap()
        let appearance = app.buttons["Appearance"]
        for _ in 0..<6 where !appearance.isHittable { app.swipeUp() }
        XCTAssertTrue(appearance.isHittable)
        appearance.tap()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
        let display = app.buttons["temperature.display"]
        XCTAssertTrue(display.exists)
        display.tap()
        app.buttons["Offset"].tap()
        display.tap()
        app.buttons["Degrees"].tap()
        let zones = app.buttons["temperature.zones"]
        zones.tap()
        app.buttons["On selection"].tap()
        capture(app, "Appearance-light")
    }

    func testDialDragAndButtonsUseTheSelectedTemperatureScale() {
        let app = launch(layout: "cards")
        let dial = app.descendants(matching: .any).matching(identifier: "Target temperature").firstMatch
        XCTAssertTrue(dial.waitForExistence(timeout: 10))
        let start = dial.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.15))
        let finish = dial.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        start.press(forDuration: 0.1, thenDragTo: finish)
        let neutral = NSPredicate { _, _ in (dial.value as? String)?.hasPrefix("0,") == true }
        expectation(for: neutral, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        app.buttons["Increase temperature"].tap()
        let warmer = NSPredicate { _, _ in (dial.value as? String)?.hasPrefix("+1,") == true }
        expectation(for: warmer, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        capture(app, "Cards-dial-adjusted")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
