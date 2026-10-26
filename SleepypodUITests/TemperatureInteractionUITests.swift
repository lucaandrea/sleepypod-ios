import XCTest

@MainActor final class TemperatureInteractionUITests: XCTestCase {
    private func launch(layout: String = "stage", scenario: String = "complete", control: String = "dial") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "", "-tempControl", control, "-temperatureLayout", layout, "-temperatureDisplay", "degrees", "-stageAutoReturn", "YES", "-uiContextScenario", scenario]
        app.launch(); XCTAssertTrue(app.buttons["Temp"].firstMatch.waitForExistence(timeout: 15)); return app
    }

    func testStagePinchAutoReturnRotateAndReset() {
        let app = launch()
        let scene = app.otherElements["thermalBed.scene"].firstMatch
        XCTAssertTrue(scene.waitForExistence(timeout: 8)); reveal(scene, app)
        let original = scene.value as? String; XCTAssertNotNil(original)
        scene.pinch(withScale: 1.2, velocity: 1)
        XCTAssertNotEqual(scene.value as? String, original); capture(app, "Controls-stage-zoomed")
        let returned = NSPredicate(format: "value == %@", original ?? "")
        expectation(for: returned, evaluatedWith: scene)
        waitForExpectations(timeout: 10); waitForCameraAnimation()
        scene.coordinate(withNormalizedOffset: .init(dx: 0.2, dy: 0.5)).press(forDuration: 0.1, thenDragTo: scene.coordinate(withNormalizedOffset: .init(dx: 0.8, dy: 0.5)))
        XCTAssertNotEqual(scene.value as? String, original); capture(app, "Controls-stage-rotated")
        let reset = app.buttons["Reset view"]; reveal(reset, app); reset.tap()
        XCTAssertEqual(scene.value as? String, original); waitForCameraAnimation(); capture(app, "Controls-stage-reset")
    }

    func testSimultaneousNoticesAndHoldChoicesStayReachable() {
        let app = launch(layout: "cards", scenario: "notices")
        let restore = app.buttons["Re-enable"]; reveal(restore, app)
        XCTAssertTrue(restore.isEnabled); capture(app, "Controls-pump-notice")
        let completed = app.staticTexts["Priming complete"]; reveal(completed, app); capture(app, "Controls-prime-notice")
        let snooze = app.buttons["Snooze 5 min"]; reveal(snooze, app)
        XCTAssertTrue(snooze.isEnabled); XCTAssertTrue(app.buttons["Stop"].exists); capture(app, "Controls-alarm-notice")
        let hold = app.buttons["temperature.hold"].firstMatch
        reveal(hold, app)
        for label in ["15 min", "30 min", "1 hr", "2 hr"] {
            reveal(hold, app); hold.tap()
            let option = app.buttons[label].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 3)); option.tap()
            expectation(for: NSPredicate(format: "value == %@", label), evaluatedWith: hold)
            waitForExpectations(timeout: 3)
            // Wait for menu dismissal before opening the next choice, especially at large text.
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["15 min"].firstMatch)
            waitForExpectations(timeout: 3)
        }
        capture(app, "Controls-manual-hold")
        XCTAssertTrue(app.buttons["Resume"].exists)
    }

    func testGlobalSchedulePauseAndResumeRequireReviewAndRetainSavedPoints() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "schedule", "-appearance", "Light"]
        app.launch()
        let control = app.switches["schedule.global.left"]
        XCTAssertTrue(control.waitForExistence(timeout: 15)); reveal(control, app)
        XCTAssertEqual(control.value as? String, "1"); capture(app, "Controls-schedules-active")
        control.tap()
        let pause = app.buttons["Pause all schedules"]
        XCTAssertTrue(pause.waitForExistence(timeout: 3)); capture(app, "Controls-schedules-pause-review"); pause.tap()
        expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: control)
        waitForExpectations(timeout: 6); capture(app, "Controls-schedules-paused")
        reveal(control, app); control.tap()
        let resume = app.buttons["Enable all schedules"]
        XCTAssertTrue(resume.waitForExistence(timeout: 3)); capture(app, "Controls-schedules-enable-review"); resume.tap()
        expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: control)
        waitForExpectations(timeout: 6)
        XCTAssertTrue(app.buttons["Schedule options"].exists); capture(app, "Controls-schedules-restored")
    }

    private func waitForCameraAnimation() {
        let rendered = expectation(description: "The 0.7-second camera return has rendered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { rendered.fulfill() }
        wait(for: [rendered], timeout: 2)
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<35 {
            let scroll = app.scrollViews.firstMatch, bounds = scroll.frame.intersection(app.frame)
            let top = max(bounds.minY + 8, app.navigationBars.firstMatch.frame.maxY + 8)
            let tabs = app.tabBars.firstMatch, bottom = tabs.exists ? min(bounds.maxY - 12, tabs.frame.minY - 8) : bounds.maxY - 16
            let visible = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bottom - top))
            let frame = element.exists ? element.frame : .zero
            if element.exists, element.isHittable, visible.contains(frame) { return }
            let direction = frame.isEmpty || frame.midY >= visible.midY ? 1.0 : -1.0
            let distance = min(0.4, max(0.08, abs(frame.midY - visible.midY) / max(bounds.height, 1)))
            scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.5 + direction * distance / 2)).press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.5 - direction * distance / 2)))
        }
        XCTFail("Cannot reach \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = title; attachment.lifetime = .keepAlways; add(attachment)
    }
}
